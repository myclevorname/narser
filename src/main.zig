const std = @import("std");
const narser = @import("narser");

const NixArchive = narser.NixArchive;
const fatal = std.process.fatal;

const max_depth: usize = 256;

const help_message =
    \\narser: Nix ARchive parSER
    \\
    \\Options:
    \\    -h, -?  Display this help message
    \\    -l, -L  Long listing (ls)
    \\    -r, -R  Recurse (ls)
    \\    -x      Archive of file is executable (pack, hash)
    \\    -n      Archive of file is not executable (default on standard input)
    \\            (pack, hash)
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
    \\Internal commands:
    \\    complete <CUR> <ARG ...>
    \\    complete <FILE> <CUR> <ARG ...>
    \\        Return a newline-separated list of suggestions for the bash completion
    \\        script. If FILE is provided, preprocess and cache the archive.
    \\
;

const LsOptions = struct { long: bool, recursive: bool };

pub fn ls(writer: *std.Io.Writer, archive: NixArchive, root: NixArchive.Node, opts: LsOptions) !void {
    var node = root;

    if (opts.long) switch (node.contents(archive)) {
        .directory => {},
        .file, .symlink => return try printPath(writer, archive, node, root, true),
    } else switch (node.contents(archive)) {
        .directory => {},
        .file, .symlink => return try writer.writeAll("\n"),
    }

    node = node.contents(archive).directory orelse return;

    while (true) {
        try printPath(writer, archive, node, root, opts.long);

        if (opts.recursive and node.contents(archive) == .directory and
            node.contents(archive).directory != null)
        {
            node = node.contents(archive).directory.?;
        } else {
            while (node != root and node.next(archive) == null) {
                node = node.parent(archive).?;
            }
            if (node == root) return;
            node = node.next(archive).?;
        }
    }
}

fn printPath(
    writer: *std.Io.Writer,
    archive: NixArchive,
    node: NixArchive.Node,
    root: NixArchive.Node,
    long: bool,
) !void {
    if (long) switch (node.contents(archive)) {
        .directory => try writer.writeAll("dr-xr-xr-x                    0 "),
        .symlink => try writer.writeAll("lrwxrwxrwx                    0 "),
        .file => |metadata| {
            try writer.writeAll(if (metadata.executable) "-r-xr-xr-x" else "-r--r--r--");
            const spaces: [21]u8 = .{' '} ** (31 - "-r-xr-xr-x".len);
            const len_size = if (metadata.contents.len == 0) 1 else 1 + std.math.log10_int(metadata.contents.len);
            try writer.print("{s}{} ", .{ spaces[len_size..], metadata.contents.len });
        },
    };

    var cur = node;
    var buf: [max_depth][]const u8 = undefined;
    const count: usize = blk: for (0..max_depth) |i| {
        buf[i] = if (cur != root) cur.name(archive).? else "";
        cur = if (cur != root) cur.parent(archive).? else break :blk i + 1;
    } else return error.OutOfMemory;

    var iter = std.mem.reverseIterator(buf[0 .. count - 1]);

    if (count != 1) {
        try writer.print(".", .{});

        while (iter.next()) |x| {
            try writer.print("/{s}", .{x});
        }
    }

    if (long and node.contents(archive) == .symlink)
        try writer.print(" -> {s}", .{node.contents(archive).symlink});

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
    const stdout = std.fs.File.stdout();
    var stdout_buffer: [4096 * 32]u8 = undefined;
    var fw = stdout.writer(&stdout_buffer);
    const writer = &fw.interface;

    var stdin_buffer: [4096]u8 = undefined;
    var inr = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin_reader = &inr.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var processed_args: std.ArrayList([]const u8) = .empty;
    defer processed_args.deinit(allocator);

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
        var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

        var hash_buffer: [2048]u8 = undefined;
        var hash_upd = hasher.writer().adaptToNewApi(&hash_buffer);
        const used_writer = if (use_hasher) &hash_upd.new_interface else writer;

        const argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", argument)) {
            try NixArchive.dumpFileDirect(
                allocator,
                stdin_reader,
                opts.executable,
                inr.getSize() catch null,
                used_writer,
            );
        } else {
            var symlink_buffer: [std.fs.max_path_bytes]u8 = undefined;

            if (std.fs.cwd().readLink(argument, &symlink_buffer)) |target| {
                try NixArchive.dumpSymlinkDirect(target, used_writer);
            } else |_| {
                const stat = try std.fs.cwd().statFile(argument);
                switch (stat.kind) {
                    .sym_link => fatal("Failed to read the symlink target", .{}),
                    .directory => {
                        var dir = try std.fs.cwd().openDir(argument, .{ .iterate = true });
                        defer dir.close();
                        try NixArchive.dumpDirectoryDirect(allocator, dir, used_writer);
                    },
                    else => {
                        var file = try std.fs.cwd().openFile(argument, .{});
                        defer file.close();
                        var fbuf: [4096]u8 = undefined;
                        var fr = file.reader(&fbuf);
                        const is_executable: bool = (try file.mode() & 0o111) != 0;
                        try NixArchive.dumpFileDirect(
                            allocator,
                            &fr.interface,
                            is_executable,
                            fr.getSize() catch null,
                            used_writer,
                        );
                    },
                }
            }
        }

        if (use_hasher) {
            used_writer.flush() catch unreachable;
            const sha256_hash = hasher.finalResult();
            var base64_hash: [44]u8 = undefined;

            _ = std.base64.standard.Encoder.encode(&base64_hash, &sha256_hash);

            try writer.print("sha256-{s}\n", .{base64_hash});
        }
    } else if (std.mem.eql(u8, "ls", command)) {
        var argument = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", argument)) argument = "/dev/fd/0";
        var file = try std.fs.cwd().openFile(argument, .{});
        defer file.close();

        var file_buf: [4096]u8 = undefined;
        var file_reader = file.reader(&file_buf);

        var archive = try NixArchive.fromReader(
            allocator,
            &file_reader.interface,
            .{ .discard_file_contents = true },
        );
        defer archive.deinit();

        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];
        const root = NixArchive.Node.subPath(.root, archive, subpath) catch |e| switch (e) {
            error.NotDir => fatal("In archive: expected directory, found file", .{}),
            error.FileNotFound => fatal("In archive: file not found", .{}),
            error.OutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
            error.NestedTooDeep => fatal("Too many nested symlinks", .{}),
        };
        try ls(writer, archive, root, .{ .recursive = opts.recurse, .long = opts.long_listing });
    } else if (std.mem.eql(u8, "cat", command)) {
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";
        const subpath = if (processed_args.items.len < 3) "/" else processed_args.items[2];

        var file = try std.fs.cwd().openFile(archive_path, .{});
        var file_buf: [4096]u8 = undefined;
        var fr = file.reader(&file_buf);

        var archive = try NixArchive.fromReader(allocator, &fr.interface, .{});
        defer archive.deinit();

        switch (NixArchive.Node.contents(.root, archive)) {
            .directory => |child| if (child == null) fatal("Archive is an empty directory", .{}),
            .file => {},
            .symlink => fatal("narser does not support following symbolic links to the filesystem", .{}),
        }

        const sub = NixArchive.Node.subPath(.root, archive, subpath) catch |e| switch (e) {
            error.NotDir => fatal("In archive: expected directory, found file", .{}),
            error.FileNotFound => fatal("In archive: file not found", .{}),
            error.OutsideArchive => fatal("narser does not support following symbolic links to the filesystem", .{}),
            error.NestedTooDeep => fatal("Too many nested symlinks", .{}),
        };

        switch (sub.contents(archive)) {
            .file => |metadata| try writer.writeAll(metadata.contents),
            .symlink => unreachable,
            .directory => fatal("In archive: expected file, found directory", .{}),
        }
    } else if (std.mem.eql(u8, "unpack", command)) {
        var archive_path = if (processed_args.items.len < 2) "-" else processed_args.items[1];
        if (std.mem.eql(u8, "-", archive_path)) archive_path = "/dev/fd/0";

        var file = try std.fs.cwd().openFile(archive_path, .{});
        var file_buf: [4096]u8 = undefined;
        var fr = file.reader(&file_buf);

        var archive = try NixArchive.fromReader(allocator, &fr.interface, .{});
        defer archive.deinit();

        const target_path = if (processed_args.items.len < 3) null else processed_args.items[2];

        switch (NixArchive.Node.contents(.root, archive)) {
            .directory => {
                var dir = try std.fs.cwd().makeOpenPath(target_path orelse ".", .{});
                defer dir.close();
                try archive.unpackDirectory(dir);
            },
            .file => |metadata| if (target_path == null or std.mem.eql(u8, "-", target_path.?))
                try writer.writeAll(metadata.contents)
            else
                try std.fs.cwd().writeFile(.{
                    .sub_path = target_path.?,
                    .data = metadata.contents,
                    .flags = .{ .mode = if (metadata.executable) 0o777 else 0o666 },
                }),
            .symlink => |target| if (target_path) |path|
                try std.fs.cwd().symLink(target, path, .{})
            else
                fatal("Target path required", .{}),
        }
    } else if (std.mem.eql(u8, "complete", command))
        unreachable // TODO
    else
        fatal("Invalid command '{s}'", .{command});

    try writer.flush();
}
