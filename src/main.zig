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
        var argument = args.next() orelse "-";
        if (std.mem.eql(u8, "-", argument)) argument = "/dev/fd/0";
        const stat = try std.fs.cwd().statFile(argument);
        switch (stat.kind) {
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const target = try std.fs.cwd().readLink(argument, &buffer);

                var archive = try narser.NarArchive.fromSymlink(allocator, target);
                defer archive.deinit();

                try archive.dump(writer);
            },
            .directory => {
                var dir = try std.fs.cwd().openDir(argument, .{ .iterate = true });
                defer dir.close();
                var archive = try narser.NarArchive.fromDirectory(allocator, dir);
                defer archive.deinit();

                try archive.dump(writer);
            },
            else => {
                const contents = try std.fs.cwd().readFileAlloc(allocator, argument, std.math.maxInt(usize));
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
    } else if (std.mem.eql(u8, "cat", command)) {
        var archive_path = args.next() orelse "-";
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";
        const subpath = args.next() orelse ".";

        const contents = try std.fs.cwd().readFileAlloc(allocator, archive_path, std.math.maxInt(usize));
        defer allocator.free(contents);

        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();

        var cur = archive.root;

        switch (cur.data) {
            .directory => |child| if (child == null) fatal("Archive \"{s}\" is an empty directory", .{archive_path}),
            .file => {},
            .symlink => fatal("narser does not support following symbolic links to the filesystem", .{}),
        }

        var symlinks: std.BoundedArray([]const u8, 4096) = .{};

        symlinks.appendAssumeCapacity(subpath);

        comptime std.debug.assert(std.fs.path.sep == '/');
        while (symlinks.pop()) |full_first_path| {
            const first_part_len = std.mem.indexOfScalar(u8, full_first_path, '/');
            const first = if (first_part_len) |len| full_first_path[0..len] else full_first_path;
            const rest = if (first_part_len) |len| full_first_path[len+1..] else "";
            if (rest.len != 0) symlinks.appendAssumeCapacity(rest);

            if (std.mem.eql(u8, first, ".") or first.len == 0) continue;
            if (std.mem.eql(u8, first, "..")) {
                if (cur.parent) |parent| cur = parent;
                continue;
            }

            cur = if (cur.data == .directory)
                cur.data.directory orelse return error.FileNotFound
            else @panic(cur.name.?);
            find: while (true) {
                switch (std.mem.order(u8, cur.name.?, first)) {
                    .lt => {},
                    .eq => break :find,
                    .gt => return error.FileNotFound,
                }
                cur = cur.next orelse return error.FileNotFound;
            }
            if (symlinks.len != 0) switch (cur.data) {
                .directory => {},
                .file => return error.IsFile,
                .symlink => |target| {
                    if (std.mem.startsWith(u8, target, "/"))
                        fatal("narser does not support following symbolic links to the filesystem", .{});
                    try symlinks.append(target);
                    cur = cur.parent.?;
                },
            };
        }

        switch (cur.data) {
            .file => |metadata| try writer.writeAll(metadata.contents),
            .symlink => unreachable,
            .directory => fatal("Expected file, found directory", .{}),
        }
    } else fatal("Invalid command '{s}'", .{command});
}
