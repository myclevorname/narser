const std = @import("std");
const narser = @import("narser");

const fatal = std.process.fatal;

const max_depth: usize = 256;

const help_message =
    \\narser: Nix ARchive parSER
    \\
    \\Options:
    \\    -h, -?  Display this help message
    \\    -l, -L  Long listing (ls only)
    \\    -r, -R  Recurse (ls only)
    \\    -x      Standard input is executable (pack only)
    \\
    \\Commands:
    \\    unpack <ARCHIVE> <PATH>
    \\    unpack [ARCHIVE [PATH]]
    \\        Unpack ARCHIVE into PATH. If ARCHIVE is an archive of a symlink, then
    \\        PATH is required. Otherwise, PATH defaults to standard output for a file
    \\        archive and the current working directory for a directory archive. If
    \\        PATH is omitted, then ARCHIVE defaults to standard input and can be
    \\        omitted.
    \\
    \\    pack [PATH]
    \\        Pack PATH into a Nix Archive and print the contents to standard output.
    \\        If PATH is omitted, read from standard input as a file.
    \\
    \\    ls [ARCHIVE [PATH]]
    \\        Show a directory listing of ARCHIVE starting from path PATH. PATH
    \\        defaults to the archive root if omitted, and ARCHIVE defaults to
    \\        standard input if omitted.
    \\
    \\    cat [ARCHIVE [PATH]]
    \\        Read the file at PATH from ARCHIVE. If PATH is omitted, then ARCHIVE is
    \\        assumed to be a file archive. If ARCHIVE is omitted, then the archive is
    \\        read from standard input.
    \\
;

const LsOptions = struct { long: bool, recursive: bool };

pub fn ls(archive: *const narser.NarArchive, writer: anytype, opts: LsOptions) !void {
    var node = archive.root;

    if (opts.long) switch (node.data) {
        .directory => {},
        .file, .symlink => return try printPath(node, writer, true),
    } else switch (node.data) {
        .directory => {},
        .file, .symlink => return try writer.writeAll("\n"),
    }

    node = node.data.directory orelse return;

    while (true) {
        try printPath(node, writer, opts.long);

        if (opts.recursive and node.data == .directory and node.data.directory != null) {
            node = node.data.directory.?;
        } else {
            while ((node.entry orelse return).next == null) {
                node = node.entry.?.parent;
            }
            node = node.entry.?.next.?;
        }
    }
}

fn printPath(node: *const narser.Object, writer: anytype, long: bool) !void {
    if (long) switch (node.data) {
        .directory => try writer.writeAll("dr-xr-xr-x                    0 "),
        .symlink => try writer.writeAll("lrwxrwxrwx                    0 "),
        .file => |metadata| {
            try writer.writeAll(if (metadata.is_executable) "-r-xr-xr-x" else "-r--r--r--");
            const spaces: [21]u8 = .{' '} ** (31 - "-r-xr-xr-x".len);
            const len_size = if (metadata.contents.len == 0) 1 else 1 + std.math.log10_int(metadata.contents.len);
            try writer.print("{s}{} ", .{ spaces[len_size..], metadata.contents.len });
        },
    };

    var cur: ?*const narser.Object = node;
    var buf: [max_depth][]u8 = undefined;
    const count: usize = blk: for (0..max_depth) |i| {
        if (cur) |x| {
            buf[i] = if (x.entry) |e| e.name else "";
            cur = if (x.entry) |e| e.parent else null;
        } else break :blk i;
    } else return error.OutOfMemory;

    var iter = std.mem.reverseIterator(buf[0 .. count - 1]);

    if (count != 1) {
        try writer.print(".", .{});

        while (iter.next()) |x| {
            try writer.print("/{s}", .{x});
        }
    }

    if (long and node.data == .symlink) try writer.print(" -> {s}", .{node.data.symlink});

    try writer.print("\n", .{});
}

const OptsIter = struct {
    current: ?[]const u8,
    iter: *std.process.ArgIterator,
    finished_options: bool = false,
    in_option: bool = false,

    const Option = union(enum) {
        option: u8,
        argument: []const u8,
    };

    fn init(iter: *std.process.ArgIterator) OptsIter {
        return .{ .iter = iter, .current = iter.next() };
    }

    fn next(self: *OptsIter) ?Option {
        blk: while (self.current != null) {
            std.debug.assert(!(self.in_option and self.finished_options));
            if (self.in_option) {
                switch (self.current.?.len) {
                    0 => unreachable,
                    1 => {
                        const opt = self.current.?[0];
                        self.current = self.iter.next();
                        self.in_option = false;
                        return .{ .option = opt };
                    },
                    else => {
                        const opt = self.current.?[0];
                        self.current = self.current.?[1..];
                        return .{ .option = opt };
                    },
                }
            } else {
                if (self.finished_options) {
                    const arg = self.current;
                    self.current = self.iter.next();
                    return .{ .argument = arg orelse return null };
                } else {
                    if (std.mem.startsWith(u8, self.current.?, "-")) {
                        if (self.current.?.len == 1) {
                            const arg = self.current;
                            self.current = self.iter.next();
                            return .{ .argument = arg orelse return null };
                        } else if (std.mem.eql(u8, self.current.?, "--")) {
                            self.finished_options = true;
                            const arg = self.iter.next();
                            self.current = self.iter.next();
                            return .{ .argument = arg orelse return null };
                        } else {
                            self.in_option = true;
                            self.current = self.current.?[1..];
                            continue :blk;
                        }
                    } else {
                        const arg = self.current;
                        self.current = self.iter.next();
                        return .{ .argument = arg orelse return null };
                    }
                }
            }
            unreachable;
        }
        return null;
    }
};

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
    _ = args.skip();

    var processed_args: std.ArrayList([]const u8) = .init(allocator);
    defer processed_args.deinit();

    var opts_iter = OptsIter.init(&args);
    const Options = struct {
        show_help: bool = false,
        long_listing: bool = false,
        recurse: bool = false,
        executable: bool = false,
    };
    var opts: Options = .{};

    while (opts_iter.next()) |arg| switch (arg) {
        .option => |opt| switch (opt) {
            'h', '?' => opts.show_help = true,
            'l', 'L' => opts.long_listing = true,
            'r', 'R' => opts.recurse = true,
            'x' => opts.executable = true,
            else => fatal("Invalid option '{c}'\n{s}", .{ opt, help_message }),
        },
        .argument => |str| try processed_args.append(str),
    };

    if (opts.show_help or processed_args.items.len == 0) return try writer.writeAll(help_message);

    const command = processed_args.items[0];
    if (std.mem.eql(u8, "pack", command)) {
        const argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", argument)) {
            try narser.dumpFile(std.io.getStdIn(), opts.executable, writer);
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
                        try narser.dumpFile(file, null, writer);
                    },
                }
            }
        }
    } else if (std.mem.eql(u8, "ls", command)) {
        var argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", argument)) argument = "/dev/fd/0";
        const contents = try std.fs.cwd().readFileAlloc(
            allocator,
            argument,
            std.math.maxInt(usize),
        );
        defer allocator.free(contents);

        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();

        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];
        archive.root = archive.root.subPath(subpath) catch |e| switch (e) {
            error.IsFile => fatal("In archive: expected directory, found file", .{}),
            error.FileNotFound => fatal("In archive: file not found", .{}),
            error.PathOutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
            error.Overflow => fatal("Too many nested symlinks", .{}),
        };
        archive.root.entry = null;
        try ls(&archive, writer, .{ .recursive = opts.recurse, .long = opts.long_listing });
    } else if (std.mem.eql(u8, "cat", command)) {
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";
        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];

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
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";

        const contents = try std.fs.cwd().readFileAlloc(allocator, archive_path, std.math.maxInt(usize));
        defer allocator.free(contents);

        var archive = try narser.NarArchive.fromSlice(allocator, contents);
        defer archive.deinit();

        const target_path = if (processed_args.items.len < 3) null else processed_args.items[2];

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
