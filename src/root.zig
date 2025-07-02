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
        expectMatch(&to_parse, "nix-archive-1") catch return error.NotANar;

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
                try cur.object.insertChild(next);
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

        try writeTokens(writer, &.{.magic});

        loop: while (true) {
            if (node.parent != null) {
                try writeTokens(writer, &.{.directory_entry});
                try strWriter(node.name.?, writer);
                try writeTokens(writer, &.{.node});
            }

            try writeTokens(writer, &.{.l_paren});
            switch (node.data) {
                .directory => |child| {
                    try writeTokens(writer, &.{.directory});
                    if (child) |next| {
                        node = next;
                        continue;
                    }
                },
                .file => |data| {
                    try writeTokens(writer, &.{.file});
                    if (data.is_executable) try writeTokens(writer, &.{.executable_file});
                    try writeTokens(writer, &.{.file_contents});
                    try strWriter(data.contents, writer);
                },
                .symlink => |link| {
                    try writeTokens(writer, &.{.symlink});
                    try strWriter(link, writer);
                },
            }
            if (node.parent != null) try writeTokens(writer, &.{ .r_paren, .r_paren });
            while (node.next == null) {
                node = node.parent orelse break :loop;
                if (node.parent != null) try writeTokens(writer, &.{ .r_paren, .r_paren });
            } else node = node.next.?;
        }
        try writeTokens(writer, &.{.r_paren});
    }

    pub fn unpackDir(self: *const NarArchive, target_dir: std.fs.Dir) !void {
        var items: std.BoundedArray(std.fs.Dir, 256) = .{};
        defer if (items.len > 1) for (items.slice()[1..]) |*dir| dir.close();
        if (self.root.data.directory != null) items.appendAssumeCapacity(target_dir);

        var current_node = self.root.data.directory.?;

        const lastItem = struct {
            fn f(array: anytype) ?@TypeOf(array.buffer[0]) {
                const slice = array.slice();
                return if (slice.len == 0) null else slice[slice.len - 1];
            }
        }.f;

        while (lastItem(items)) |cwd| {
            switch (current_node.data) {
                .file => |metadata| {
                    try cwd.writeFile(.{
                        .sub_path = current_node.name.?,
                        .data = metadata.contents,
                        .flags = .{ .mode = if (metadata.is_executable) 0o777 else 0o666 },
                    });
                },
                .symlink => |target| {
                    cwd.deleteFile(current_node.name.?) catch {};
                    try cwd.symLink(target, current_node.name.?, .{});
                },
                .directory => |child| {
                    if (std.mem.eql(u8, current_node.name.?, "..") or
                        std.mem.containsAtLeastScalar(u8, current_node.name.?, 1, '/'))
                        return error.MaliciousArchive;
                    if (std.mem.eql(u8, ".", current_node.name.?))
                        return error.MaliciousArchive;
                    try cwd.makeDir(current_node.name.?);
                    if (child) |node| {
                        try items.ensureUnusedCapacity(1);
                        const next = try cwd.openDir(current_node.name.?, .{});
                        items.appendAssumeCapacity(next);
                        current_node = node;
                        continue;
                    }
                },
            }
            while (current_node.next == null) {
                current_node = current_node.parent orelse return;
                var dir = items.pop().?;
                if (current_node.parent != null) dir.close();
            }
            current_node = current_node.next.?;
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
            const ret = self.current;

            if (ret) |cur| self.current = cur.next;
            return ret;
        }
    };

    try writeTokens(writer, &.{ .magic, .l_paren, .directory });

    var iterators: std.BoundedArray(struct {
        dir_iter: std.fs.Dir.Iterator,
        object: *NamedObject,
        object_iter: ObjectIterator = .{},
    }, 256) = .{};
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

            try cur.object.object.insertChild(&next_object.object);

            cur.object_iter.current = cur.object.object.data.directory;
        };

        while (cur.object_iter.next()) |object| {
            try writeTokens(writer, &.{.directory_entry});
            try strWriter(object.name.?, writer);
            try writeTokens(writer, &.{ .node, .l_paren });

            switch (object.data) {
                .directory => {
                    try writeTokens(writer, &.{.directory});
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
                    try writeTokens(writer, &.{.file});
                    if (stat.mode & 0o111 != 0) try writeTokens(writer, &.{.executable_file});
                    try writeTokens(writer, &.{.file_contents});

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
                    try writer.writeAll(zeroes[0..@intCast((8 - stat.size % 8) % 8)]);
                },
                .symlink => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    try writeTokens(writer, &.{.symlink});

                    const link = try cur.dir_iter.dir.readLink(object.name.?, &buf);

                    try strWriter(link, writer);
                },
            }
            try writeTokens(writer, &.{ .r_paren, .r_paren });
            objects.destroy(@fieldParentPtr("object", object));
        } else while (cur.object_iter.current == null) {
            if (cur.object.object.parent == null) break :next_dir;
            try writeTokens(writer, &.{ .r_paren, .r_paren });
            cur.dir_iter.dir.close();

            objects.destroy(cur.object);
            _ = iterators.pop().?;

            cur = &iterators.buffer[iterators.len - 1];
        }
    }
    try writeTokens(writer, &.{.r_paren});
}

pub fn dumpFile(file: std.fs.File, writer: anytype) !void {
    const stat = try file.stat();
    const is_executable = stat.mode & 0o111 != 0;
    try writer.writeAll(comptime str("nix-archive-1") ++ str("(") ++ str("type") ++ str("regular"));
    if (is_executable) try writer.writeAll(comptime str("executable") ++ str(""));
    try writer.writeAll(comptime str("contents"));

    try writer.writeInt(u64, stat.size, .little);

    var left = stat.size;
    var buf: [4096]u8 = undefined;

    while (left != 0) {
        const read = try file.read(&buf);
        if (read == 0) return error.UnexpectedEof;
        try writer.writeAll(buf[0..read]);
        left -= read;
    }

    const zeroes: [8]u8 = .{0} ** 8;
    try writer.writeAll(zeroes[0..@intCast((8 - stat.size % 8) % 8)]);

    try writer.writeAll(comptime str(")"));
}

pub fn dumpSymlink(target: []const u8, writer: anytype) !void {
    try writer.writeAll(comptime str("nix-archive-1") ++ str("(") ++
        str("type") ++
        str("symlink") ++ str("target"));
    try strWriter(target, writer);

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

    pub fn insertChild(self: *Object, child: *Object) error{DuplicateObjectName}!void {
        if (self.data.directory) |first|
            switch (mem.order(u8, first.name.?, child.name.?)) {
                .lt => {
                    var left = first;
                    while (left.next != null and mem.order(u8, left.name.?, child.name.?) == .lt) {
                        left = left.next.?;
                    } else switch (mem.order(u8, left.name.?, child.name.?)) {
                        .eq => return error.DuplicateObjectName,
                        .lt => {
                            left.next = child;
                            child.prev = left;
                        },
                        .gt => {
                            child.prev = left.prev;
                            child.next = left;
                            if (left.prev) |p| p.next = child;
                            left.prev = child;
                        },
                    }
                },
                .eq => return error.DuplicateObjectName,
                .gt => {
                    first.prev = child;
                    child.next = first;
                    self.data.directory = child;
                },
            }
        else
            self.data.directory = child;
    }

    pub fn subPath(self: *const Object, subpath: []const u8) !*const Object {
        var cur = self;
        var parts: std.BoundedArray([]const u8, 4096) = .{};
        parts.appendAssumeCapacity(subpath);

        comptime std.debug.assert(std.fs.path.sep == '/');
        while (parts.pop()) |full_first_path| {
            const first_part_len = std.mem.indexOfScalar(u8, full_first_path, '/');
            const first = if (first_part_len) |len| full_first_path[0..len] else full_first_path;
            const rest = if (first_part_len) |len| full_first_path[len + 1 ..] else "";
            if (rest.len != 0) parts.appendAssumeCapacity(rest);

            if (std.mem.eql(u8, first, ".") or first.len == 0) continue;
            if (std.mem.eql(u8, first, "..")) {
                if (cur.parent) |parent| cur = parent;
                continue;
            }

            cur = if (cur.data == .directory)
                cur.data.directory orelse return error.FileNotFound
            else
                @panic(cur.name.?);
            find: while (true) {
                switch (std.mem.order(u8, cur.name.?, first)) {
                    .lt => {},
                    .eq => break :find,
                    .gt => return error.FileNotFound,
                }
                cur = cur.next orelse return error.FileNotFound;
            }
            switch (cur.data) {
                .directory => {},
                .file => if (parts.len != 0) return error.IsFile,
                .symlink => |target| {
                    if (std.mem.startsWith(u8, target, "/")) return error.PathOutsideArchive;
                    try parts.append(target);
                    cur = cur.parent.?;
                },
            }
        }
        return cur;
    }
};

pub const File = struct {
    is_executable: bool,
    contents: []u8,
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidFormat,
    WrongDirectoryOrder,
    DuplicateObjectName,
    NotANar,
};

const Token = enum {
    magic,
    l_paren,
    r_paren,
    directory,
    file,
    symlink,
    executable_file,
    file_contents,
    directory_entry,
    node,
};

fn writeTokens(writer: anytype, comptime tokens: []const Token) !void {
    comptime var concatenated: []const u8 = "";

    comptime {
        for (tokens) |token| concatenated = concatenated ++ switch (token) {
            .magic => str("nix-archive-1"),
            .l_paren => str("("),
            .r_paren => str(")"),
            .directory => str("type") ++ str("directory"),
            .file => str("type") ++ str("regular"),
            .symlink => str("type") ++ str("symlink") ++ str("target"),
            .executable_file => str("executable") ++ str(""),
            .file_contents => str("contents"),
            .directory_entry => str("entry") ++ str("(") ++ str("name"),
            .node => str("node"),
        };
    }

    try writer.writeAll(concatenated);
}

fn prevLevel(slice: *[]u8, depth: *u64) EncodeError!void {
    try expectMatch(slice, ")");
    if (depth.* == 0) unreachable else depth.* -= 1;
}

fn nextLevel(slice: *[]u8, depth: *u64) EncodeError!void {
    try expectMatch(slice, "(");
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

fn strWriter(string: []const u8, writer: anytype) !void {
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

test "more complex" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/complex/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/complex", .{ .iterate = true });
    defer root.close();

    const expected = @embedFile("tests/complex.nar") ++ @embedFile("tests/complex.nar") ++
        @embedFile("tests/complex_empty.nar") ++ @embedFile("tests/complex_empty.nar");

    var array: std.BoundedArray(u8, expected.len) = .{};
    const writer = array.writer();

    var cds = std.io.changeDetectionStream(expected, writer);
    const cds_writer = cds.writer();

    {
        try dumpDirectory(allocator, root, cds_writer);

        var archive = try NarArchive.fromDirectory(allocator, root);
        defer archive.deinit();

        try archive.dump(cds_writer);
    }
    {
        var empty = try root.openDir("empty", .{ .iterate = true });
        defer empty.close();

        try dumpDirectory(allocator, empty, cds_writer);

        var archive = try NarArchive.fromDirectory(allocator, empty);
        defer archive.deinit();

        try archive.dump(cds_writer);
    }

    // TODO: Add more dumps and froms
    if (cds.changeDetected()) return error.NoMatch;
}
