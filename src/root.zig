const std = @import("std");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const mem = std.mem;
const divCeil = std.math.divCeil;

pub const NarArchive = struct {
    root: *Object,
    pool: std.heap.MemoryPool(Object),

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    /// TODO: Add validation for directory listing order
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self: NarArchive = .{
            .pool = .init(allocator),
            .root = undefined,
        };
        errdefer self.pool.deinit();

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
                    error.UnbalancedParens => return err,
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
                @panic("symlink handling");
            } else if (matchAndSlide(&to_parse, "directory")) {
                next.data = .{ .directory = undefined };
                parent = next;
                prev = null;
                in_directory = true;
            } else return error.InvalidFormat;
        }

        if (recursion_depth != 0) return error.UnbalancedParens;
        if (to_parse.len != 0) return error.InvalidFormat;

        self.root = root orelse return error.InvalidFormat;
        return self;
    }

    pub fn deinit(self: *NarArchive) void {
        self.pool.deinit();
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
    UnbalancedParens,
};

fn prevLevel(slice: *[]u8, depth: *u64) EncodeError!void {
    if (!matchAndSlide(slice, ")")) return error.InvalidFormat;
    if (depth.* == 0) return error.UnbalancedParens else depth.* -= 1;
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

fn str(comptime string: []const u8) []const u8 {
    var buffer: [8]u8 = undefined;
    mem.writeInt(u64, &buffer, string.len, .little);
    return buffer ++ string ++ (if (string.len % 8 == 0) [_]u8{} else [_]u8{0} ** (8 - (string.len % 8)));
}

test "single file" {
    var buf: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const data = try NarArchive.fromSlice(fba.allocator(), @constCast(@embedFile("tests/README.nar")));
    try expectEqualStrings(@embedFile("tests/README.out"), data.root.data.file.contents);
}

test "directory containing a single file" {
    var buf: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const data = try NarArchive.fromSlice(fba.allocator(), @constCast(@embedFile("tests/hello.nar")));
    const dir = data.root;
    const file = dir.data.directory.?;
    try expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.file.contents);
    try expectEqualStrings("main.zig", file.name.?);
}

test "a file, a directory, and some more files" {
    var buf: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const data = try NarArchive.fromSlice(fba.allocator(), @constCast(@embedFile("tests/dir-and-files.nar")));

    const dir = data.root.*.data.directory.?.*;
    try expectEqualStrings("dir", dir.name.?);

    const file1 = dir.next.?.*;
    try expectEqual(file1.next, null);
    try expectEqualStrings("file1", file1.name.?);
    try expectEqual(false, file1.data.file.is_executable);
    try expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?.*;
    try expectEqualStrings("file2", file2.name.?);
    try expectEqual(true, file2.data.file.is_executable);
    try expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.next.?.*;
    try expectEqual(false, file3.data.file.is_executable);
    try expectEqualStrings("file3", file3.name.?);
    try expectEqualStrings("nevermind\n", file3.data.file.contents);
    try expectEqual(null, file3.next);
}
