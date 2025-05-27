const std = @import("std");
const tests_path = @import("tests").tests_path;

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const mem = std.mem;
const divCeil = std.math.divCeil;

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

        var recursion_depth: usize = 0;
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
            .prev = null,
            .next = null,
            .name = null,
            .data = .{ .directory = null },
        };
        self.root = root_node;

        var walker = try root.walk(allocator);
        defer walker.deinit();

        var prev_node = root_node;

        var prev_depth: usize = 0;
        var next_depth: usize = undefined;

        while (try walker.next()) |entry| {
            var next_node = try self.pool.create();
            next_node.* = .{
                .parent = undefined,
                .prev = null,
                .next = null,
                .name = try self.arena.allocator().dupe(u8, entry.basename),
                .data = undefined,
            };

            next_depth = 1 + std.mem.count(u8, entry.path, "/");
            next_node.data = switch (entry.kind) {
                .directory => .{ .directory = null },
                .sym_link => .{ .symlink = blk: {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    break :blk try entry.dir.readLink(entry.basename, &buf);
                } },
                else => .{ .file = .{
                    .contents = try entry.dir.readFileAlloc(
                        self.arena.allocator(),
                        entry.basename,
                        std.math.maxInt(usize),
                    ),
                    .is_executable = (try entry.dir.statFile(entry.basename)).mode & 0x01 == 1,
                } },
            };

            blk: {
                if (next_depth > prev_depth) {
                    prev_node.data.directory = next_node;
                    next_node.parent = prev_node;
                } else {
                    for (next_depth..prev_depth) |_| {
                        prev_node = prev_node.parent.?;
                    }
                    prev_depth = next_depth;
                    next_node.parent = prev_node.parent;

                    search: while (prev_node.prev) |prev| {
                        switch (mem.order(u8, prev.name.?, entry.basename)) {
                            .lt => break :search,
                            .eq => return error.DuplicateObjectName,
                            .gt => prev_node = prev,
                        }
                    }
                    search: while (true) {
                        switch (mem.order(u8, entry.basename, prev_node.name.?)) {
                            .lt => break :search,
                            .eq => return error.DuplicateObjectName,
                            .gt => prev_node = prev_node.next orelse {
                                prev_node.next = next_node;
                                next_node.prev = prev_node;
                                break :blk;
                            },
                        }
                    }

                    // insert next_node to the left of prev_node, adjusting
                    // prev_node.parent.?.data.directory if needed
                    if (prev_node.prev == null) {
                        prev_node.parent.?.data.directory = next_node;
                        prev_node.prev = next_node;
                        next_node.next = prev_node;
                        break :blk;
                    }

                    next_node.prev = prev_node.prev;
                    next_node.next = prev_node;
                    prev_node.prev.?.next = next_node;
                    prev_node.prev = next_node;
                }
            }

            prev_node = next_node;
            prev_depth = next_depth;
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
            .prev = null,
            .next = null,
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
            .prev = null,
            .next = null,
            .name = null,
            .data = .{ .symlink = copy },
        };

        return .{
            .arena = arena,
            .pool = pool,
            .root = node,
        };
    }

    pub fn dump(self: *NarArchive, writer: anytype) !void {
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

pub const Object = struct {
    parent: ?*Object,
    prev: ?*Object,
    next: ?*Object,
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

    const len = mem.readInt(u64, slice.*[0..8], .little);
    const padded_len = (divCeil(u64, len, 8) catch unreachable) * 8;

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

    try writer.print("{s}{s}{s}", .{ &buffer, string, zeroes[0..(8 - string.len % 8) % 8] });
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
    //try expectEqualStrings("dir", dir.name.?);

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
