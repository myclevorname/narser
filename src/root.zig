const std = @import("std");

const divCeil = std.math.divCeil;

pub const NarArchive = struct {
    root: Object,
    node_pool: std.heap.MemoryPool(Object),

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    /// TODO: Add validation for directory listing order
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self = .{
            .pool = undefined,
            .root = .{
                .parent = null,
                .data = undefined,
            },
        };

        var to_parse = slice;
        if (!try matchAndSlide(&to_parse, str("nix-archive-1"))) return error.InvalidFormat;
        var pool = .init(allocator);

        var recursion_depth: usize = 0;
        var current_object = &self.pool;

        while (true) {
            if (!matchAndSlide(&to_parse, "type")) return error.InvalidFormat;
            if (matchAndSlide(&to_parse, "regular")) {
                @compileError("regular file handling");
            } else if (matchAndSlide(&to_parse, "symlink")) {
                @compileError("symlink handling");
            } else if (matchAndSlide(&to_parse, "directory")) {
                @compileError("directory handling");
            } else return error.InvalidFormat;
        }

        self.pool = pool;
        return self;
    }

    pub fn deinit(self: *NarArchive) void {
        self.pool.deinit();
        self.* = undefined;
    }
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidFormat,
    WrongDirectoryOrder,
    DuplicateObjectName,
};

/// Compares the start of a slice and a comptime-known match, and advances the slice if it matches.
fn matchAndSlide(slice: *[]const u8, comptime match: []const u8) EncodeError!bool {
    match = match ++ ([0]**8 - match.len % 8);

    if (slice.len < match.len) return error.InvalidFormat;

    const matched = std.mem.eql(u8, slice.*[0..match.len]);
    if (matched) slice.* = slice.*[match.len..];
    return matched;
}

fn unStr(slice: *[]const u8) EncodeError![]const u8 {
    if (slice.len < 8) return error.InvalidFormat;

    const len: u64 = @ptrCast(slice[0..8]).*;
    const padded_len = divCeil(u64, len, 8);

    if (slice.len < 8 + padded_len) return error.InvalidFormat;

    slice.* = slice.*[8..];

    result = slice.*[0..len];

    if (!std.mem.allEqual(u8, slice.*[len..padded_len], 0)) return error.InvalidFormat;

    slice.* = slice.*[padded_len..];

    return result;
}

fn str(comptime string: []const u8) [8 * divCeil(usize, string.len, 8) + 8]u8 {
    var buffer = [undefined]**8;
    std.mem.writeInt(u64, &buffer, string.len, .little);
    return buffer ++ string ++ [0]**((8 -% string.len) % 8);
}

pub const Object = struct {
    parent: ?*Object,
    prev: ?*Object = null,
    next: ?*Object = null,
    data: Data,

    pub const Data = union(enum) {
        file: File,
        symlink: []u8,
        directory: ?*Object,
    };
};

pub const File = struct {
    is_executable: bool,
    data: []u8,
};
