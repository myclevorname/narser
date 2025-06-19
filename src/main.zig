const std = @import("std");
const narser = @import("narser");

const fatal = std.process.fatal;

const max_depth: usize = 256;

pub fn lsRecursive(archive: *const narser.NarArchive, writer: anytype) !void {
    var node = archive.root;

    switch (node.data) {
        .directory => {},
        .file, .symlink => return try writer.writeAll("\n"),
    }

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

fn printPath(node: *const narser.Object, writer: anytype) !void {
    var cur: ?*const narser.Object = node;
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

pub fn main() !void {
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
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
        const argument = args.next() orelse "-";
        if (std.mem.eql(u8, "-", argument)) {
            try narser.dumpFile(std.io.getStdIn(), writer);
        } else {
            var symlink_buffer: [std.fs.max_path_bytes]u8 = undefined;

            if (std.fs.cwd().readLink(argument, &symlink_buffer)) |target| {
                try narser.dumpSymlink(target, writer);
            } else |_| {
                const stat = try std.fs.cwd().statFile(argument);
                switch (stat.kind) {
                    .sym_link => fatal("Failed to read the symlink target", .{}),
                    .directory => {
                        var dir = try std.fs.cwd().openDir(argument, .{ .iterate = true });
                        defer dir.close();
                        try narser.dumpDirectory(allocator, dir, writer);
                    },
                    else => {
                        var file = try std.fs.cwd().openFile(argument, .{});
                        defer file.close();
                        try narser.dumpFile(file, writer);
                    },
                }
            }
        }
    } else if (std.mem.eql(u8, "ls", command)) {
        var argument = args.next() orelse "-";
        if (std.mem.eql(u8, "-", argument)) argument = "/dev/fd/0";
        const contents = try std.fs.cwd().readFileAlloc(
            allocator,
            argument,
            std.math.maxInt(usize),
        );
        defer allocator.free(contents);
        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();
        try lsRecursive(&archive, writer);
    } else if (std.mem.eql(u8, "cat", command)) {
        var archive_path = args.next() orelse "-";
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";
        const subpath = args.next() orelse ".";

        const contents = try std.fs.cwd().readFileAlloc(allocator, archive_path, std.math.maxInt(usize));
        defer allocator.free(contents);

        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();

        switch (archive.root.data) {
            .directory => |child| if (child == null) fatal("Archive is an empty directory", .{}),
            .file => {},
            .symlink => fatal("narser does not support following symbolic links to the filesystem", .{}),
        }

        const sub = archive.root.subPath(subpath) catch |e| switch (e) {
            error.IsFile => fatal("In archive: expected directory, found file", .{}),
            error.FileNotFound => fatal("In archive: file not found", .{}),
            error.PathOutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
            error.Overflow => fatal("Too many nested symlinks", .{}),
        };

        switch (sub.data) {
            .file => |metadata| try writer.writeAll(metadata.contents),
            .symlink => unreachable,
            .directory => fatal("In archive: expected file, found directory", .{}),
        }
    } else if (std.mem.eql(u8, "unpack", command)) {
        var archive_path = args.next() orelse "-";
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";

        const contents = try std.fs.cwd().readFileAlloc(allocator, archive_path, std.math.maxInt(usize));
        defer allocator.free(contents);

        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();

        const target_path = args.next();

        switch (archive.root.data) {
            .directory => {
                var dir = try std.fs.cwd().makeOpenPath(target_path orelse ".", .{});
                defer dir.close();
                try archive.unpackDir(dir);
            },
            .file => |metadata| if (target_path == null or std.mem.eql(u8, "-", target_path.?))
                try writer.writeAll(metadata.contents)
            else
                try std.fs.cwd().writeFile(.{
                    .sub_path = target_path.?,
                    .data = metadata.contents,
                    .flags = .{ .mode = if (metadata.is_executable) 0o777 else 0o666 },
                }),
            .symlink => |target| if (target_path) |path|
                try std.fs.cwd().symLink(target, path, .{})
            else
                fatal("Target path required", .{}),
        }
    } else fatal("Invalid command '{s}'", .{command});
}
