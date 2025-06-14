const std = @import("std");
const tests_path = @import("tests").tests_path;

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const mem = std.mem;
const divCeil = std.math.divCeil;

/// An alternative @alignOf and std.mem.Alignment.of that changes output based on compiler version.
inline fn alignOf(comptime T: type) @typeInfo(@TypeOf(std.ArrayListAligned)).@"fn".params[1].type.? {
    return switch (@typeInfo(@TypeOf(std.ArrayListAligned)).@"fn".params[1].type.?) {
        ?std.mem.Alignment => std.mem.Alignment.of(T),
        ?u29 => @alignOf(T),
        else => |x| @compileError("Expected ?std.mem.Alignment or ?u29, found \"" ++ @typeName(x) ++ "\""),
    };
}

/// A Nix Archive file.
///
/// Preconditions:
///
/// 1. The object pointed to by root must have no name, no previous or next, and no parent.
///
/// 2. The object a directory points to must have a name, have no previous object, and has a parent
/// set to said directory.
///
/// 3. All objects in a directory must be sorted by name and must be unique within a directory.
pub const NarArchive = struct {
    arena: std.heap.ArenaAllocator,
    pool: std.heap.MemoryPool(Object),
    root: *Object,

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self: NarArchive = .{
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
        };
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        var to_parse = slice;
        if (!matchAndSlide(&to_parse, "nix-archive-1")) return error.InvalidFormat;

        var recursion_depth: u64 = 0;
        var prev: ?*Object = null;
        var parent: ?*Object = null;

        var root: ?*Object = null;
        var in_directory = false;

        try nextLevel(&to_parse, &recursion_depth);

        loop: while (true) {
            blk: while (true) {
                if (recursion_depth == 0) break :loop;
                prevLevel(&to_parse, &recursion_depth) catch |err| switch (err) {
                    error.InvalidFormat => break :blk,
                    else => unreachable,
                };

                // If the depth is even, then we just left a Nar object. The ')" for a file is
                // already handled, so it must be a directory.
                // If it is odd, then we are at the next directory entry.
                //
                // The only two places where parentheses are used are directory entries and NAR
                // objects. Directory entries cannot directly contain directory entries and NAR
                // objects cannot directly contain NAR objects, so checking the depth's parity is
                // okay.
                if (recursion_depth % 2 == 0) {
                    prev = parent;
                    parent = if (parent) |p| p.parent else null;
                }
                continue :blk;
            }

            var next = try self.pool.create();
            next.* = .{
                .prev = prev,
                .next = null,
                .parent = parent,
                .data = undefined,
                .name = null,
            };

            if (in_directory) {
                try expectMatch(&to_parse, "entry");
                try nextLevel(&to_parse, &recursion_depth);
                try expectMatch(&to_parse, "name");
                next.name = try unstr(&to_parse);

                if (prev) |p| switch (mem.order(u8, p.name.?, next.name.?)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                };

                try expectMatch(&to_parse, "node");
                try nextLevel(&to_parse, &recursion_depth);
            }
            if (prev) |obj| {
                obj.next = next;
            } else if (parent) |obj| obj.data.directory = next;
            if (root == null) root = next;

            try expectMatch(&to_parse, "type");
            if (matchAndSlide(&to_parse, "regular")) {
                const is_executable = if (matchAndSlide(&to_parse, "executable"))
                    (if (matchAndSlide(&to_parse, "")) true else return error.InvalidFormat)
                else
                    false;
                try expectMatch(&to_parse, "contents");
                const contents = try unstr(&to_parse);
                next.data = .{ .file = .{ .is_executable = is_executable, .contents = contents } };

                prev = next;
                try prevLevel(&to_parse, &recursion_depth);
            } else if (matchAndSlide(&to_parse, "symlink")) {
                try expectMatch(&to_parse, "target");
                next.data = .{ .symlink = try unstr(&to_parse) };
                prev = next;
                try prevLevel(&to_parse, &recursion_depth);
            } else if (matchAndSlide(&to_parse, "directory")) {
                next.data = .{ .directory = undefined };
                parent = next;
                prev = null;
                in_directory = true;
            } else return error.InvalidFormat;
        }

        self.root = root orelse return error.InvalidFormat;
        return self;
    }

    pub fn fromDirectory(allocator: std.mem.Allocator, root: std.fs.Dir) !NarArchive {
        var self: NarArchive = .{
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
        };
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        const root_node = try self.pool.create();
        root_node.* = .{
            .parent = null,
            .name = null,
            .data = .{ .directory = null },
        };
        self.root = root_node;

        var iters: std.BoundedArray(struct {
            iterator: std.fs.Dir.Iterator, // holds the directory
            object: *Object,
        }, 256) = .{};

        iters.appendAssumeCapacity(.{
            .iterator = root.iterate(),
            .object = root_node,
        });

        errdefer if (iters.len > 1) for (iters.slice()[1..]) |*x| x.iterator.dir.close();

        while (iters.len != 0) {
            var cur = &iters.slice()[iters.len - 1];
            const entry = try cur.iterator.next();

            if (entry) |e| {
                const next = try self.pool.create();
                switch (e.kind) {
                    .directory => {
                        next.* = .{
                            .parent = cur.object,
                            .name = try self.arena.allocator().dupe(u8, e.name),
                            .data = .{ .directory = null },
                        };
                        var child = try cur.iterator.dir.openDir(e.name, .{ .iterate = true });
                        iters.append(.{
                            .iterator = child.iterate(),
                            .object = next,
                        }) catch @panic("Implementation limit reached: Directory nested too deeply");
                    },
                    .sym_link => {
                        next.* = .{
                            .parent = cur.object,
                            .name = try self.arena.allocator().dupe(u8, e.name),
                            .data = .{ .symlink = undefined },
                        };
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        const link = try cur.iterator.dir.readLink(e.name, &buf);
                        next.data.symlink = try self.arena.allocator().dupe(u8, link);
                    },
                    else => {
                        next.* = .{
                            .parent = cur.object,
                            .name = try self.arena.allocator().dupe(u8, e.name),
                            .data = .{ .file = undefined },
                        };
                        const stat = try cur.iterator.dir.statFile(e.name);
                        const contents = try cur.iterator.dir.readFileAllocOptions(
                            self.arena.allocator(),
                            e.name,
                            std.math.maxInt(usize),
                            std.math.cast(usize, stat.size) orelse std.math.maxInt(usize),
                            alignOf(u8).?,
                            null,
                        );
                        next.data.file = .{
                            .contents = contents,
                            .is_executable = stat.mode & 1 == 1,
                        };
                    },
                }
                if (cur.object.data.directory) |first|
                    switch (mem.order(u8, first.name.?, next.name.?)) {
                        .lt => {
                            var left = first;
                            while (left.next != null and mem.order(u8, left.name.?, next.name.?) == .lt) {
                                left = left.next.?;
                            } else switch (mem.order(u8, left.name.?, next.name.?)) {
                                .eq => {
                                    @branchHint(.cold);
                                    return error.Unexpected;
                                },
                                .lt => {
                                    left.next = next;
                                    next.prev = left;
                                },
                                .gt => {
                                    next.prev = left.prev;
                                    next.next = left;
                                    if (left.prev) |p| p.next = next;
                                    left.prev = next;
                                },
                            }
                        },
                        .eq => return error.Unexpected,
                        .gt => {
                            first.prev = next;
                            next.next = first;
                            cur.object.data.directory = next;
                        },
                    }
                else
                    cur.object.data.directory = next;
            } else {
                if (iters.len > 1) cur.iterator.dir.close();
                _ = iters.pop().?;
            }
        }

        return self;
    }

    /// Creates a NAR archive containing a single file given its contents.
    pub fn fromFileContents(
        allocator: std.mem.Allocator,
        contents: []const u8,
        is_executable: bool,
    ) std.mem.Allocator.Error!NarArchive {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var pool = std.heap.MemoryPool(Object).init(arena.allocator());
        errdefer arena.deinit();

        const copy = try arena.allocator().dupe(u8, contents);

        const node = try pool.create();

        node.* = .{
            .parent = null,
            .name = null,
            .data = .{ .file = .{ .is_executable = is_executable, .contents = copy } },
        };

        return .{
            .arena = arena,
            .pool = pool,
            .root = node,
        };
    }

    /// Creates a NAR archive containing a single symlink given its target.
    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []const u8,
    ) std.mem.Allocator.Error!NarArchive {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var pool = std.heap.MemoryPool(Object).init(arena.allocator());
        errdefer arena.deinit();

        const node = try pool.create();

        const copy = try arena.allocator().dupe(u8, target);

        node.* = .{
            .parent = null,
            .name = null,
            .data = .{ .symlink = copy },
        };

        return .{
            .arena = arena,
            .pool = pool,
            .root = node,
        };
    }

    pub fn dump(self: *const NarArchive, writer: anytype) !void {
        var node = self.root;

        try writer.writeAll(comptime str("nix-archive-1"));

        while (true) {
            if (node.parent != null) {
                try writer.writeAll(comptime str("entry") ++ str("(") ++ str("name"));
                try strWriter(node.name.?, writer);
                try writer.writeAll(comptime str("node"));
            }

            try writer.writeAll(comptime str("(") ++ str("type"));
            switch (node.data) {
                .directory => |child| {
                    try writer.writeAll(comptime str("directory"));
                    if (child) |next| {
                        node = next;
                        continue;
                    }
                },
                .file => |data| {
                    try writer.writeAll(comptime str("regular"));
                    if (data.is_executable) try writer.writeAll(comptime str("executable") ++ str(""));
                    try writer.writeAll(comptime str("contents"));
                    try strWriter(data.contents, writer);
                },
                .symlink => |link| {
                    try writer.writeAll(comptime str("symlink") ++ str("target"));
                    try strWriter(link, writer);
                },
            }
            try writer.writeAll(comptime str(")"));
            if (node.parent != null) {
                try writer.writeAll(comptime str(")"));
            }
            while (node.parent != null and node.next == null) {
                try writer.writeAll(comptime str(")"));
                node = node.parent.?;
                if (node.parent != null) try writer.writeAll(comptime str(")"));
            } else if (node.parent != null) node = node.next.? else return;
        }
    }

    pub fn deinit(self: *NarArchive) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn dumpDirectory(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    writer: anytype,
) !void {
    const NamedObject = struct {
        name: [std.fs.max_path_bytes]u8 = undefined,
        object: Object,
    };

    const ObjectIterator = struct {
        current: ?*Object = null,

        const Self = @This();

        fn next(self: *Self) ?*Object {
            if (self.current) |cur| {
                self.current = cur.next;
                return cur;
            } else return null;
        }
    };

    try writer.writeAll(comptime str("nix-archive-1") ++ str("(") ++ str("type") ++ str("directory"));

    var iterators = try allocator.create(std.BoundedArray(struct {
        dir_iter: std.fs.Dir.Iterator,
        object: *NamedObject,
        object_iter: ObjectIterator = .{},
    }, 2048)); // TODO: Change to 4096
    iterators.* = .{};
    defer allocator.destroy(iterators);
    defer if (iterators.len > 1) for (iterators.slice()[1..]) |*iter| iter.dir_iter.dir.close();

    var objects = std.heap.MemoryPool(NamedObject).init(allocator);
    defer objects.deinit();

    const root_object = try objects.create();

    root_object.object = .{
        .parent = null,
        .name = null,
        .data = .{ .directory = null },
    };

    iterators.appendAssumeCapacity(.{
        .dir_iter = root_dir.iterate(),
        .object = root_object,
    });

    next_dir: while (true) {
        var cur = &iterators.buffer[iterators.len - 1];

        if (cur.object_iter.current == null) while (try cur.dir_iter.next()) |entry| {
            const next_object = try objects.create();

            @memcpy(next_object.name[0..entry.name.len], entry.name);
            next_object.object = .{
                .parent = &cur.object.object,
                .name = next_object.name[0..entry.name.len],
                .data = switch (entry.kind) {
                    .directory => .{ .directory = null },
                    .sym_link => .{ .symlink = undefined },
                    else => .{ .file = undefined },
                },
            };

            // copy+paste from NarArchive.fromDirectory
            const next = &next_object.object;
            if (cur.object.object.data.directory) |first|
                switch (mem.order(u8, first.name.?, next.name.?)) {
                    .lt => {
                        var left = first;
                        while (left.next != null and mem.order(u8, left.name.?, next.name.?) == .lt) {
                            left = left.next.?;
                        } else switch (mem.order(u8, left.name.?, next.name.?)) {
                            .eq => {
                                @branchHint(.cold);
                                return error.Unexpected;
                            },
                            .lt => {
                                left.next = next;
                                next.prev = left;
                            },
                            .gt => {
                                next.prev = left.prev;
                                next.next = left;
                                if (left.prev) |p| p.next = next;
                                left.prev = next;
                            },
                        }
                    },
                    .eq => return error.Unexpected,
                    .gt => {
                        first.prev = next;
                        next.next = first;
                        cur.object.object.data.directory = next;
                    },
                }
            else
                cur.object.object.data.directory = next;

            cur.object_iter.current = cur.object.object.data.directory;
        };

        while (cur.object_iter.next()) |object| {
            try writer.writeAll(comptime str("entry") ++ str("(") ++ str("name"));
            try strWriter(object.name.?, writer);
            try writer.writeAll(comptime str("node") ++ str("(") ++ str("type"));

            switch (object.data) {
                .directory => {
                    try writer.writeAll(comptime str("directory"));
                    try iterators.ensureUnusedCapacity(1);
                    const next_dir = try cur.dir_iter.dir.openDir(object.name.?, .{ .iterate = true });

                    const next = iterators.addOneAssumeCapacity();
                    next.* = .{
                        .object = @fieldParentPtr("object", object),
                        .dir_iter = next_dir.iterateAssumeFirstIteration(),
                    };
                    continue :next_dir;
                },
                .file => {
                    const stat = try cur.dir_iter.dir.statFile(object.name.?);
                    try writer.writeAll(comptime str("regular"));
                    if (stat.mode & 0o111 != 0) try writer.writeAll(comptime str("executable") ++ str(""));
                    try writer.writeAll(comptime str("contents"));

                    try writer.writeInt(u64, stat.size, .little);
                    var left = stat.size;

                    var file = try cur.dir_iter.dir.openFile(object.name.?, .{});
                    defer file.close();

                    while (left != 0) {
                        var buf: [4096 * 8]u8 = undefined;
                        const read = try file.read(&buf);
                        try writer.writeAll(buf[0..read]);
                        left -= read;
                    }

                    const zeroes: [8]u8 = .{0} ** 8;
                    if (stat.size % 8 != 0) try writer.writeAll(zeroes[0 .. (8 - stat.size % 8) % 8]);

                    try writer.writeAll(comptime str(")") ++ str(")"));
                    objects.destroy(@fieldParentPtr("object", object));
                },
                .symlink => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    try writer.writeAll(comptime str("symlink") ++ str("target"));

                    const link = try cur.dir_iter.dir.readLink(object.name.?, &buf);

                    try strWriter(link, writer);

                    try writer.writeAll(comptime str(")") ++ str(")"));
                    objects.destroy(@fieldParentPtr("object", object));
                },
            }
        } else while (cur.object_iter.current == null) {
            if (cur.object.object.parent == null) break :next_dir;
            try writer.writeAll(comptime str(")") ++ str(")"));
            cur.dir_iter.dir.close();

            objects.destroy(cur.object);

            _ = iterators.pop().?;

            cur = &iterators.buffer[iterators.len - 1];
        }
    }
    try writer.writeAll(comptime str(")"));
}

pub const Object = struct {
    parent: ?*Object,
    prev: ?*Object = null,
    next: ?*Object = null,
    name: ?[]u8,
    data: Data,

    pub const Data = union(enum) {
        file: File,
        symlink: []u8,
        directory: ?*Object,
    };
};

pub const File = struct {
    is_executable: bool,
    contents: []u8,
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidFormat,
    WrongDirectoryOrder,
    DuplicateObjectName,
};

fn prevLevel(slice: *[]u8, depth: *u64) EncodeError!void {
    if (!matchAndSlide(slice, ")")) return error.InvalidFormat;
    if (depth.* == 0) unreachable else depth.* -= 1;
}

fn nextLevel(slice: *[]u8, depth: *u64) EncodeError!void {
    if (!matchAndSlide(slice, "(")) return error.InvalidFormat;
    depth.* += 1;
}

/// Compares the start of a slice and a comptime-known match, and advances the slice if it matches.
fn matchAndSlide(slice: *[]u8, comptime match_: []const u8) bool {
    const match = comptime str(match_);
    if (match.len % 8 != 0) @compileError("match is not a multiple of 8 and is of size " ++
        std.fmt.digits2(@intCast(match.len)));

    if (slice.len < match.len) return false;

    const matched = mem.eql(u8, slice.*[0..match.len], match);
    if (matched) slice.* = slice.*[match.len..];
    return matched;
}

fn expectMatch(slice: *[]u8, comptime match: []const u8) !void {
    if (!matchAndSlide(slice, match)) return error.InvalidFormat;
}

fn expectNoMatch(slice: *[]u8, comptime match: []const u8) !void {
    if (matchAndSlide(slice, match)) return error.InvalidFormat;
}

fn unstr(slice: *[]u8) EncodeError![]u8 {
    if (slice.len < 8) return error.InvalidFormat;

    const len = std.math.cast(usize, mem.readInt(u64, slice.*[0..8], .little)) orelse return error.OutOfMemory;
    const padded_len = (divCeil(usize, len, 8) catch unreachable) * 8;

    if (slice.*[8..].len < padded_len) return error.InvalidFormat;

    slice.* = slice.*[8..];

    const result = slice.*[0..len];

    if (!mem.allEqual(u8, slice.*[len..padded_len], 0)) return error.InvalidFormat;

    slice.* = slice.*[padded_len..];

    return result;
}

fn strWriter(string: []u8, writer: anytype) !void {
    var buffer: [8]u8 = undefined;
    mem.writeInt(u64, &buffer, string.len, .little);

    const zeroes: [7]u8 = .{0} ** 7;

    try writer.print("{s}{s}{s}", .{ &buffer, string, zeroes[0 .. (8 - string.len % 8) % 8] });
}

fn str(comptime string: anytype) []const u8 {
    comptime {
        var buffer: [8]u8 = undefined;
        mem.writeInt(u64, &buffer, string.len, .little);

        const zeroes: [7]u8 = .{0} ** 7;
        return buffer ++ string ++ (if (string.len % 8 == 0) [0]u8{} else zeroes[0 .. (8 - string.len % 8) % 8]);
    }
}

test "single file" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/README.nar")));
    defer data.deinit();

    try expectEqualStrings(@embedFile("tests/README.out"), data.root.data.file.contents);
}

test "directory containing a single file" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/hello.nar")));
    defer data.deinit();

    const dir = data.root;
    const file = dir.data.directory.?;
    try expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.file.contents);
    try expectEqualStrings("main.zig", file.name.?);
}

test "a file, a directory, and some more files" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/dir-and-files.nar")));
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try expectEqualStrings("dir", dir.name.?);

    const file1 = dir.next.?;
    try expectEqual(file1.next, null);
    try expectEqualStrings("file1", file1.name.?);
    try expectEqual(false, file1.data.file.is_executable);
    try expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try expectEqualStrings("file2", file2.name.?);
    try expectEqual(true, file2.data.file.is_executable);
    try expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.next.?;
    try expectEqual(false, file3.data.file.is_executable);
    try expectEqualStrings("file3", file3.name.?);
    try expectEqualStrings("nevermind\n", file3.data.file.contents);
    try expectEqual(null, file3.next);
}

test "a symlink" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/symlink.nar")));
    defer data.deinit();

    try expectEqualStrings("README.out", data.root.data.symlink);
}

test "nar from dir-and-files" {
    const allocator = std.testing.allocator;

    var root = try std.fs.cwd().openDir(tests_path ++ "/dir-and-files", .{ .iterate = true });
    defer root.close();

    var data = try NarArchive.fromDirectory(allocator, root);
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try expectEqualStrings("dir", dir.name.?);

    const file1 = dir.next.?;
    try expectEqual(null, file1.next);
    try expectEqualStrings("file1", file1.name.?);
    try expectEqual(false, file1.data.file.is_executable);
    try expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try expectEqualStrings("file2", file2.name.?);
    try expectEqual(true, file2.data.file.is_executable);
    try expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.next.?;
    try expectEqual(false, file3.data.file.is_executable);
    try expectEqualStrings("file3", file3.name.?);
    try expectEqualStrings("nevermind\n", file3.data.file.contents);
    try expectEqual(null, file3.next);
}

test "empty directory" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/empty", .{ .iterate = true });
    defer root.close();

    var data = try NarArchive.fromDirectory(allocator, root);
    defer data.deinit();

    try expectEqual(null, data.root.data.directory);
}

test "nar to directory to nar" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/dir-and-files.nar")));
    defer data.deinit();

    const expected = @embedFile("tests/dir-and-files.nar");

    var buffer: [2 * expected.len]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try data.dump(stream.writer());

    try std.testing.expectEqualSlices(u8, expected, stream.getWritten());
}
