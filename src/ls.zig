const std = @import("std");
const narser = @import("narser");

const max_depth: usize = 256;

pub fn lsRecursive(archive: *const narser.NarArchive, writer: anytype) !void {
    var node = archive.root;

    while (true) {
        if (node.data == .directory and node.data.directory != null) {
            node = node.data.directory.?;
        } else {
            while (node.next == null) {
                node = node.parent orelse return;
            }
            node = node.next.?;
        }
        try printPath(node, writer);
    }
}

fn printPath(node: *narser.Object, writer: anytype) !void {
    var cur: ?*narser.Object = node;
    var buf: [max_depth][]u8 = undefined;
    const count: usize = blk: for (0..max_depth) |i| {
        if (cur) |x| {
            buf[i] = x.name orelse "";
            cur = x.parent;
        } else break :blk i;
    } else return error.OutOfMemory;

    var iter = std.mem.reverseIterator(buf[0 .. count - 1]);

    if (count == 1) return;

    try writer.print(".", .{});

    while (iter.next()) |x| {
        try writer.print("/{s}", .{x});
    }
    try writer.print("\n", .{});
}
