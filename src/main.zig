const std = @import("std");
const narser = @import("narser");

const fatal = std.process.fatal;

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

    while (iter.next()) |x| {
        try writer.print("/{s}", .{x});
    }
    try writer.print("\n", .{});
}

pub fn main() !void {
    //const writer = std.io.getStdOut().writer();
    //const reader = std.io.getStdIn().reader();

    //_ = reader;

    //var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    //defer _ = gpa.deinit();

    //const allocator = gpa.allocator();

    //var args = try std.process.ArgIterator.initWithAllocator(allocator);
    //defer args.deinit();

    //// program name
    //std.debug.assert(args.skip());

    //// TODO: Improve the CLI

    //const command = args.next() orelse fatal("No command supplied", .{});

    //if (std.mem.eql(u8, "pack", command)) {
    //    const argument = args.next() orelse "-";
    //    if (args.skip() == true) fatal("Too many arguments specified", .{});
    //    if (std.mem.eql(u8, "-", argument)) {
    //        @panic("TODO: File packing");
    //    } else switch (try std.fs.cwd().statFile(argument)) {
    //        .symlink => @panic("TODO: Symlink packing"),
    //        .directory => {
    //            var dir = try std.fs.cwd().openDir(argument, .{});
    //            defer dir.close();
    //            var archive = try narser.NarArchive.fromDirectory(allocator, dir);
    //            defer archive.deinit();

    //            try archive.dump(writer);
    //        },
    //        else => @panic("TODO: File handling"),
    //    }
    //} else if (std.mem.eql(u8, "ls", command)) {
    //    const argument = args.next() orelse "-";
    //    @panic("TODO: ls");
    //} else fatal("Invalid command '{s}'", .{command});
}
