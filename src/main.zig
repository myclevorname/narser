const std = @import("std");
const narser = @import("lib");

const fatal = std.process.fatal;

const max_depth: usize = 256;

const help_message =
    \\narser: Nix ARchive parSER
    \\
    \\Options:
    \\    -h, -?  Display this help message
    \\    -l      Long listing (ls)
    \\    -r, -R  Recurse (ls)
    \\    -n      File is not executable (pack, hash)
    \\    -x      File is executable (pack, hash)
    \\    -L      Follow symlinks at the cost of speed and memory (cat)
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
    \\    hash [PATH]
    \\        Encode PATH as a Nix archive and prints its SRI hash to standard output.
    \\        If PATH is omitted, read from standard input as a file.
    \\
;

const LsOptions = struct {
    long: bool = false,
    recursive: bool = false,
};

fn ls(archive: narser.NixArchive, writer: *std.Io.Writer, opts: LsOptions) !void {
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

fn printPath(node: *const narser.NixArchive.Object, writer: *std.Io.Writer, long: bool) !void {
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

    var cur: ?*const narser.NixArchive.Object = node;
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
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096 * 64]u8 = undefined;
    var fw = std.fs.File.adaptFromNewApi(stdout).writer(&stdout_buffer);
    var writer = &fw.interface;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    const allocator = arena.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    //defer args.deinit();
    _ = args.skip();

    var processed_args: std.ArrayList([]const u8) = .empty;
    //defer processed_args.deinit(allocator);

    var opts_iter = OptsIter.init(&args);
    const Options = struct {
        show_help: bool = false,
        long_listing: bool = false,
        recurse: bool = false,
        executable: ?bool = null,
        follow: bool = false,
    };
    var opts: Options = .{};

    while (opts_iter.next()) |arg| switch (arg) {
        .option => |opt| switch (opt) {
            'h', '?' => opts.show_help = true,
            'l' => opts.long_listing = true,
            'L' => opts.follow = true,
            'r', 'R' => opts.recurse = true,
            'n' => opts.executable = false,
            'x' => opts.executable = true,
            else => fatal("Invalid option '{c}'\n{s}", .{ opt, help_message }),
        },
        .argument => |str| try processed_args.append(allocator, str),
    };

    if (opts.show_help or processed_args.items.len == 0) {
        try writer.writeAll(help_message);
        try writer.flush();
        return;
    }

    const command = processed_args.items[0];
    if (std.mem.eql(u8, "pack", command) or std.mem.eql(u8, "hash", command)) {
        const use_hasher = std.mem.eql(u8, "hash", command);

        var hash_buffer: [2048]u8 = undefined;
        var hash_upd: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&hash_buffer);
        const used_writer = if (use_hasher) &hash_upd.writer else writer;

        const argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        var in_buf: [8192]u8 = undefined;

        if (std.mem.eql(u8, "-", argument)) {
            var fr = std.Io.File.stdin().reader(io, &in_buf);
            try narser.NixArchive.packFile(
                allocator,
                &fr.interface,
                used_writer,
                opts.executable orelse false,
                fr.getSize() catch null,
            );
        } else {
            const stat = try std.Io.Dir.cwd().statPath(io, argument, .{ .follow_symlinks = false });
            switch (stat.kind) {
                .sym_link => {
                    var symlink_buffer: [std.fs.max_path_bytes]u8 = undefined;

                    const target = try std.fs.Dir.adaptFromNewApi(std.Io.Dir.cwd())
                        .readLink(argument, &symlink_buffer);
                    try narser.NixArchive.packSymlink(target, used_writer);
                },
                .directory => {
                    var dir = try std.Io.Dir.cwd().openDir(io, argument, .{ .iterate = true });
                    defer dir.close(io);
                    try narser.NixArchive.packDirectory(allocator, io, dir, used_writer);
                },
                else => {
                    var file = try std.Io.Dir.cwd().openFile(io, argument, .{});
                    defer file.close(io);
                    var fr = file.reader(io, &in_buf);
                    try narser.NixArchive.packFile(
                        allocator,
                        &fr.interface,
                        used_writer,
                        stat.mode & 0o111 != 0,
                        fr.getSize() catch null,
                    );
                },
            }
        }

        if (use_hasher) {
            used_writer.flush() catch unreachable;
            const sha256_hash = hash_upd.hasher.finalResult();
            try writer.print("sha256-{b64}\n", .{sha256_hash});
        }
    } else if (std.mem.eql(u8, "ls", command)) {
        var argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", argument)) argument = "/dev/fd/0";

        var in_file = try std.Io.Dir.cwd().openFile(io, argument, .{});
        defer in_file.close(io);

        var in_buf: [8192]u8 = undefined;
        var in_reader = in_file.reader(io, &in_buf);

        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];

        var archive = try narser.NixArchive.fromReader(allocator, &in_reader.interface, .{ .store_file_contents = false });
        //defer archive.deinit();

        archive.root = archive.root.subPath(subpath) catch |e| switch (e) {
            error.NotDir => fatal("In archive: expected directory", .{}),
            error.FileNotFound => fatal("In archive: file not found", .{}),
            error.PathOutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
            error.NestedTooDeep => fatal("Too many nested symlinks", .{}),
        };
        archive.root.entry = null;
        try ls(archive, writer, .{ .recursive = opts.recurse, .long = opts.long_listing });
    } else if (std.mem.eql(u8, "cat", command)) {
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";
        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];

        var in_file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
        defer in_file.close(io);

        var in_buf: [8192]u8 = undefined;
        var in_reader = in_file.reader(io, &in_buf);

        if (!opts.follow) {
            var iter: narser.NixArchive.UnpackIterator = .init(allocator, &in_reader.interface);
            //defer iter.deinit();

            var parts: std.ArrayList([]const u8) = .empty;
            try parts.ensureTotalCapacity(allocator, 1 + std.mem.count(u8, subpath, "/"));
            narser.normalizePath(&parts, subpath);

            const kind = try narser.NixArchive.peekType(&in_reader.interface);

            switch (kind) {
                .file => if (parts.items.len == 0) {
                    _ = (try iter.first(writer, 0)).file;
                } else return error.NotDir,
                .symlink => return error.IsSymlink,
                .directory => if (parts.items.len == 0)
                    return error.IsDir
                else {
                    std.debug.assert(try iter.first(null, 1) == .directory);
                    level: for (0..parts.items.len) |i| {
                        while (try iter.next()) |e| {
                            //std.debug.print("found '{s}' (expecting '{s}')\n", .{ e.name, parts.items[i] });
                            switch (std.mem.order(u8, e.name, parts.items[i])) {
                                .lt => {
                                    const a = iter.names.items.len;
                                    try iter.skip(e);
                                    std.debug.assert(a == iter.names.items.len);
                                },
                                .eq => {
                                    if (i == parts.items.len - 1) {
                                        if (e.kind != .file) return error.NotFile;
                                        std.debug.assert(try iter.take(e, writer) == .file);
                                        break :level;
                                    } else {
                                        if (e.kind != .directory) return error.NotDir;
                                        std.debug.assert(try iter.take(e, null) == .directory);
                                        continue :level;
                                    }
                                    comptime unreachable;
                                },
                                .gt => return error.FileNotFound,
                            }
                        } else return error.FileNotFound;
                    }
                },
            }

            // _ = try narser.NixArchive.unpackSubFile(allocator, &in_reader.interface, writer, subpath);
        } else {
            var archive = try narser.NixArchive.fromReader(allocator, &in_reader.interface, .{});
            //defer archive.deinit();

            switch (archive.root.data) {
                .directory => |child| if (child == null) fatal("Archive is an empty directory", .{}),
                .file => {},
                .symlink => fatal("narser does not support following symbolic links to the filesystem", .{}),
            }

            const sub = archive.root.subPath(subpath) catch |e| switch (e) {
                error.NotDir => fatal("In archive: expected directory", .{}),
                error.FileNotFound => fatal("In archive: file not found", .{}),
                error.PathOutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
                error.NestedTooDeep => fatal("Too many nested symlinks", .{}),
            };

            switch (sub.data) {
                .file => |metadata| try writer.writeAll(metadata.contents),
                .symlink => fatal("In archive: expected file, found symlink", .{}),
                .directory => fatal("In archive: expected file, found directory", .{}),
            }
        }
    } else if (std.mem.eql(u8, "unpack", command)) {
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";

        var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
        defer file.close(io);
        var fbuf: [4096 * 64]u8 = undefined;
        var fr = file.reader(io, &fbuf);
        const reader = &fr.interface;

        const kind = narser.NixArchive.peekType(reader) catch |e| switch (e) {
            error.NotANar => fatal("File is not a Nix archive", .{}),
            else => return e,
        };

        const target_path = if (processed_args.items.len < 3) null else processed_args.items[2];

        switch (kind) {
            .directory => {
                var dir = try std.Io.Dir.cwd().makeOpenPath(io, target_path orelse ".", .{});
                defer dir.close(io);
                var fw_buf: [4096 * 8]u8 = undefined;
                try narser.NixArchive.unpackDirectory(allocator, io, reader, dir, &fw_buf);
            },
            .file => if (target_path == null or std.mem.eql(u8, "-", target_path.?)) {
                _ = try narser.NixArchive.unpackFile(reader, writer);
            } else {
                var out = try std.Io.Dir.cwd().createFile(io, target_path.?, .{});
                defer out.close(io);
                var w = std.fs.File.adaptFromNewApi(out).writer(&.{});

                const exec = try narser.NixArchive.unpackFile(reader, &w.interface);
                try std.fs.File.adaptFromNewApi(file).chmod(if (exec) 0o777 else 0o666);
            },
            .symlink => if (target_path) |path| {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                try std.fs.Dir.adaptFromNewApi(std.Io.Dir.cwd()).symLink(
                    try narser.NixArchive.unpackSymlink(reader, &path_buf),
                    path,
                    .{},
                );
            } else fatal("Target path required", .{}),
        }
    } else fatal("Invalid command '{s}'", .{command});

    try writer.flush();
}
