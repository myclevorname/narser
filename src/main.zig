const std = @import("std");
const narser = @import("narser");

const fatal = std.process.fatal;

const max_depth: usize = 256;

pub fn lsRecursive(archive: *const narser.NarArchive, writer: anytype) !void {
    var node = archive.root;

    switch (node.data) {
        .directory => {},
        .file, .symlink => return try writer.writeAll("<\n"),
    }

    while (true) {
        if (node.data == .directory and node.data.directory != null) {
            node = node.data.directory.?;
        } else {
            while (node.list.next == null) {
                node = node.parent orelse return;
            }
            node = @fieldParentPtr("list", node.list.next.?);
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
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer bw.flush() catch @panic("Failed to fully flush stdout buffer");

    const writer = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    // program name
    std.debug.assert(args.skip());

    // TODO: Improve the CLI

    const command = args.next() orelse fatal("No command supplied", .{});

    if (std.mem.eql(u8, "pack", command)) {
        var argument = args.next();
        if (argument == null or std.mem.eql(u8, "-", argument.?)) argument = "/dev/fd/0";
        const stat = try std.fs.cwd().statFile(argument.?);
        switch (stat.kind) {
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target = try std.fs.cwd().readLink(argument.?, &buffer);

                var archive = try narser.NarArchive.fromSymlink(allocator, target);
                defer archive.deinit();

                try archive.dump(writer);
            },
            .directory => {
                var dir = try std.fs.cwd().openDir(argument.?, .{ .iterate = true });
                defer dir.close();
                var archive = try narser.NarArchive.fromDirectory(allocator, dir);
                defer archive.deinit();

                try archive.dump(writer);
            },
            else => {
                const contents = try std.fs.cwd().readFileAlloc(allocator, argument.?, std.math.maxInt(usize));
                defer allocator.free(contents);

                var archive = try narser.NarArchive.fromFileContents(
                    allocator,
                    contents,
                    stat.mode & 1 == 1,
                );
                defer archive.deinit();

                try archive.dump(writer);
            },
        }
    } else if (std.mem.eql(u8, "ls", command)) {
        const argument = args.next() orelse "-";
        const contents = try std.fs.cwd().readFileAlloc(
            allocator,
            argument,
            std.math.maxInt(usize),
        );
        defer allocator.free(contents);
        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();
        try lsRecursive(&archive, writer);
    } else fatal("Invalid command '{s}'", .{command});
}
