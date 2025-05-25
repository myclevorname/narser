const std = @import("std");

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
        const parent: ?*Object = null;

        var root: ?*Object = null;
        //var in_directory = false;

        try nextLevel(&to_parse);
        recursion_depth += 1;

        while (true) {
            if (!matchAndSlide(&to_parse, "type")) break;
            if (matchAndSlide(&to_parse, "regular")) {
                var next = try self.pool.create();
                next.* = .{
                    .prev = prev,
                    .next = null,
                    .parent = parent,
                    .data = .{ .file = undefined },
                    .name = null,
                };
                if (prev) |obj| {
                    obj.next = next;
                }

                const is_executable = if (matchAndSlide(&to_parse, "executable"))
                    (if (matchAndSlide(&to_parse, "")) true else return error.InvalidFormat)
                    else false;
                if (!matchAndSlide(&to_parse, "contents")) return error.InvalidFormat;
                const contents = try unstr(&to_parse);
                next.data.file = .{
                    .is_executable = is_executable,
                    .contents = contents,
                };

                prev = next;

                if (root == null) root = next;
            } else if (matchAndSlide(&to_parse, "symlink")) {
                @panic("symlink handling");
            } else if (matchAndSlide(&to_parse, "directory")) {
                @panic("directory handling");
            } else return error.InvalidFormat;
        }

        try prevLevel(&to_parse);
        recursion_depth -= 1;

        if (recursion_depth != 0 or to_parse.len != 0) return error.InvalidFormat;

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
};

fn prevLevel(slice: *[]u8) EncodeError!void {
    if (!matchAndSlide(slice, ")")) return error.InvalidFormat;
}

fn nextLevel(slice: *[]u8) EncodeError!void {
    if (!matchAndSlide(slice, "(")) return error.InvalidFormat;
}

/// Compares the start of a slice and a comptime-known match, and advances the slice if it matches.
fn matchAndSlide(slice: *[]u8, comptime match_: []const u8) bool {
    const match = comptime str(match_);
    if (match.len % 8 != 0) @compileError("match is not a multiple of 8 and is of size " ++
        std.fmt.digits2(@intCast(match.len)));

    if (slice.len < match.len) return false;

    const matched = std.mem.eql(u8, slice.*[0..match.len], match);
    if (matched) slice.* = slice.*[match.len..];
    return matched;
}

fn unstr(slice: *[]u8) EncodeError![]u8 {
    if (slice.len < 8) return error.InvalidFormat;

    const len = std.mem.readInt(u64, slice.*[0..8], .little);
    const padded_len = (divCeil(u64, len, 8) catch unreachable) * 8;

    if (slice.*[8..].len < padded_len) return error.InvalidFormat;

    slice.* = slice.*[8..];

    const result = slice.*[0..len];

    if (!std.mem.allEqual(u8, slice.*[len..padded_len], 0)) return error.InvalidFormat;

    slice.* = slice.*[padded_len..];

    return result;
}

fn str(comptime string: []const u8) []const u8 {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, string.len, .little);
    return buffer ++ string ++ (if (string.len % 8 == 0) [_]u8{} else [_]u8{0} ** (8 - (string.len % 8)));
}

test "single file" {
    var buf: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const data = try NarArchive.fromSlice(fba.allocator(), @constCast(@embedFile("tests/test-README.nar")));
    try std.testing.expect(std.mem.eql(u8, data.root.data.file.contents, @embedFile("tests/test-README.out")));
}
