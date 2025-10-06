const std = @import("std");
const tests_path = @import("tests").tests_path;

const Name = std.meta.Int(.unsigned, 1 + std.math.log2(std.fs.max_name_bytes));
const Target = std.meta.Int(.unsigned, 1 + std.math.log2(std.fs.max_path_bytes));

/// A Nix Archive file.
///
/// Preconditions:
///
/// 1. The object pointed to by root must have `entry` be null.
///
/// 2. The object a directory points to must have a non-null entry, have no previous object, and
/// has a parent set to said directory.
///
/// 3. All objects in a directory must be sorted by name and must be unique within a directory.
pub const NixArchive = struct {
    arena: std.heap.ArenaAllocator,
    pool: std.heap.MemoryPool(Object),
    root: *Object,
    name_pool: std.heap.MemoryPool([std.fs.max_name_bytes]u8),

    pub const Object = struct {
        /// null iff the root of the archive
        entry: ?DirectoryEntry,
        data: Data,

        pub const DirectoryEntry = struct {
            parent: *Object,
            prev: ?*Object = null,
            next: ?*Object = null,
            name: []u8,
        };

        pub const Data = union(enum) {
            file: File,
            symlink: []u8,
            directory: ?*Object,
        };

        pub const File = struct {
            is_executable: bool,
            contents: []u8,
        };

        /// Makes the child a child of the parent object. Asserts the object is a directory.
        /// This only fails if a child with the same name already exists.
        pub fn insertChild(parent: *Object, child: *Object) error{DuplicateObjectName}!void {
            std.debug.assert(parent.data == .directory);
            if (parent.data.directory) |first|
                switch (std.mem.order(u8, first.entry.?.name, child.entry.?.name)) {
                    .lt => {
                        var left = first;
                        while (left.entry.?.next != null and
                            std.mem.order(u8, left.entry.?.name, child.entry.?.name) == .lt)
                        {
                            left = left.entry.?.next.?;
                        } else switch (std.mem.order(u8, left.entry.?.name, child.entry.?.name)) {
                            .eq => return error.DuplicateObjectName,
                            .lt => {
                                left.entry.?.next = child;
                                child.entry.?.prev = left;
                            },
                            .gt => {
                                child.entry.?.prev = left.entry.?.prev;
                                child.entry.?.next = left;
                                if (left.entry.?.prev) |p| p.entry.?.next = child;
                                left.entry.?.prev = child;
                            },
                        }
                    },
                    .eq => return error.DuplicateObjectName,
                    .gt => {
                        first.entry.?.prev = child;
                        child.entry.?.next = first;
                        parent.data.directory = child;
                    },
                }
            else
                parent.data.directory = child;
        }

        /// Traverses an Object, following symbolic links.
        pub fn subPath(self: *Object, subpath: []const u8) !*Object {
            var cur = self;
            var parts_buf: [4096][]const u8 = undefined;
            var parts: std.ArrayList([]const u8) = .initBuffer(&parts_buf);
            if (self.entry != null and self.data == .symlink)
                if (self.data.symlink[0] == '/')
                    return error.PathOutsideArchive
                else
                    parts.appendAssumeCapacity(self.data.symlink);

            parts.appendAssumeCapacity(subpath);

            var limit: u16 = 0;

            comptime std.debug.assert(std.fs.path.sep == '/');
            while (parts.pop()) |full_first_path| {
                limit = std.math.add(u16, limit, 1) catch return error.NestedTooDeep;
                const first_part_len = std.mem.indexOfScalar(u8, full_first_path, '/');
                const first = if (first_part_len) |len| full_first_path[0..len] else full_first_path;
                const rest = if (first_part_len) |len| full_first_path[len + 1 ..] else "";
                if (first_part_len != null) parts.appendAssumeCapacity(rest);

                //std.debug.print("{s} {}\n", .{ full_first_path, parts.items.len });
                if (cur.data == .symlink and cur.entry != null) {
                    parts.appendBounded(cur.data.symlink) catch return error.NestedTooDeep;
                    cur = if (cur.entry) |e| e.parent else cur;
                    continue;
                }

                if (std.mem.eql(u8, first, ".") or first.len == 0) continue;
                if (std.mem.eql(u8, first, "..")) {
                    if (cur.entry) |entry| cur = entry.parent;
                    continue;
                }

                cur = if (cur.data == .directory)
                    cur.data.directory orelse
                        return error.FileNotFound
                else
                    return error.NotDir;
                find: while (true) {
                    switch (std.mem.order(u8, cur.entry.?.name, first)) {
                        .lt => {},
                        .eq => break :find,
                        .gt => return error.FileNotFound,
                    }
                    cur = cur.entry.?.next orelse
                        return error.FileNotFound;
                }
                switch (cur.data) {
                    .directory => {},
                    .file => if (parts.items.len != 0) return error.NotDir,
                    .symlink => |target| {
                        if (std.mem.startsWith(u8, target, "/")) return error.PathOutsideArchive;
                    },
                }
            }
            return cur;
        }
    };

    /// Returns the type of archive in the reader. Asserts the reader buffer is at least 80 bytes.
    pub fn peekType(reader: *std.Io.Reader) !std.meta.Tag(Object.Data) {
        const magic = getTokenString(.magic);
        const file = getTokenString(.file);
        const directory = getTokenString(.directory);
        const symlink = getTokenString(.symlink);

        if (magic.len + directory.len != 80) {
            @compileLog(magic.len + directory.len);
            @compileError("archiveType doc comment needs updated");
        }

        std.debug.assert(reader.buffer.len >= magic.len + directory.len);

        if (!std.mem.eql(u8, try reader.peek(magic.len), magic)) return error.NotANar;

        if (std.mem.eql(u8, try reader.peek(magic.len + file.len), magic ++ file))
            return .file
        else if (std.mem.eql(
            u8,
            try reader.peek(magic.len + directory.len),
            magic ++ directory,
        ))
            return .directory
        else if (std.mem.eql(
            u8,
            try reader.peek(magic.len + symlink.len),
            magic ++ symlink,
        ))
            return .symlink
        else
            return error.InvalidToken;
    }

    pub const FromReaderOptions = struct {
        /// The length of each file is always stored
        store_file_contents: bool = true,
    };

    pub const FromReaderError = std.mem.Allocator.Error || std.Io.Reader.Error || error{
        NotANar,
        InvalidToken,
        InvalidPadding,
        TargetTooSmall,
        TargetTooLarge,
        NameTooSmall,
        NameTooLarge,
        DuplicateObjectName,
        WrongDirectoryOrder,
        FileTooLarge,
    };

    /// Returns a Nix archive from the given reader. Data after the end of the archive is not read.
    pub fn fromReader(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        options: FromReaderOptions,
    ) FromReaderError!NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
            .name_pool = undefined,
        };
        self.name_pool = .init(self.arena.allocator());
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        var current = try self.pool.create();
        current.* = .{ .entry = null, .data = undefined };

        self.root = current;

        const State = enum {
            start,
            get_object_type,
            get_entry,
            get_entry_inner,
            file,
            directory,
            symlink,
            next,
            next_skip_end,
            leave_directory,
            end,
        };
        state: switch (State.start) {
            .start => {
                expectToken(reader, .magic) catch |e| switch (e) {
                    error.ReadFailed => return e,
                    error.InvalidToken => return error.NotANar,
                };

                continue :state .get_object_type;
            },
            .get_object_type => {
                if (try takeToken(reader, .file))
                    continue :state .file
                else if (try takeToken(reader, .directory))
                    continue :state .directory
                else if (try takeToken(reader, .symlink))
                    continue :state .symlink
                else
                    return error.InvalidToken;
            },
            .get_entry => {
                try expectToken(reader, .directory_entry);
                continue :state .get_entry_inner;
            },
            .get_entry_inner => {
                const name = try takeName(reader);

                const copied = try self.name_pool.create();
                @memcpy(copied[0..name.len], name);
                current.entry.?.name = copied[0..name.len];

                if (current.entry.?.prev) |p| switch (std.mem.order(u8, p.entry.?.name, current.entry.?.name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                };
                try expectToken(reader, .directory_entry_inner);
                continue :state .get_object_type;
            },
            .directory => {
                current.data = .{ .directory = null };
                if (current.entry != null) {
                    if (try takeToken(reader, .directory_entry_end)) continue :state .next_skip_end;
                } else {
                    if (try takeToken(reader, .archive_end))
                        return self;
                }

                // there must be a child at this point

                const child = try self.pool.create();
                current.data.directory = child;
                child.* = .{
                    .entry = .{
                        .parent = current,
                        .name = undefined,
                    },
                    .data = undefined,
                };
                current = child;
                continue :state .get_entry;
            },
            .file => {
                current.data = .{ .file = .{ .contents = undefined, .is_executable = false } };
                if (try takeToken(reader, .executable_file)) current.data.file.is_executable = true;
                try expectToken(reader, .file_contents);

                const len = std.math.cast(usize, try reader.takeInt(u64, .little)) orelse
                    return error.FileTooLarge; // e.g. len of 8 GB on a 32-bit system
                if (options.store_file_contents) {
                    var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
                    reader.streamExact64(&aw.writer, len) catch |e| switch (e) {
                        inline error.EndOfStream, error.ReadFailed => |t| return t,
                        error.WriteFailed => return error.OutOfMemory,
                    };
                    current.data.file.contents = aw.toOwnedSlice() catch unreachable;
                } else {
                    reader.discardAll64(len) catch |e| switch (e) {
                        error.ReadFailed => return e,
                        error.EndOfStream => return error.InvalidToken,
                    };
                    current.data.file.contents.len = len;
                }
                const pad = reader.take(padding(len)) catch |e| switch (e) {
                    error.ReadFailed => return e,
                    error.EndOfStream => return error.InvalidToken,
                };
                if (!std.mem.allEqual(u8, pad, 0)) return error.InvalidPadding;
                continue :state .next;
            },
            .symlink => {
                const name = try takeTarget(reader);
                const copied = try self.arena.allocator().dupe(u8, name);
                current.data = .{ .symlink = copied };
                continue :state .next;
            },
            .next => {
                if (current.entry != null) {
                    try expectToken(reader, .directory_entry_end);
                    continue :state .leave_directory;
                } else continue :state .end;
            },
            .next_skip_end => {
                continue :state (if (current.entry != null) .leave_directory else .end);
            },
            .leave_directory => {
                while (current.entry != null and try takeToken(reader, .directory_entry_end)) {
                    current = current.entry.?.parent;
                } else {
                    if (current.entry != null and try takeToken(reader, .directory_entry)) {
                        const next = try self.pool.create();
                        current.entry.?.next = next;
                        next.* = .{
                            .entry = .{
                                .parent = current.entry.?.parent,
                                .prev = current,
                                .name = undefined,
                            },
                            .data = undefined,
                        };
                        current = next;
                        continue :state .get_entry_inner;
                    } else {
                        continue :state .end;
                    }
                }
            },
            .end => {
                try expectToken(reader, .archive_end);
                return self;
            },
        }
        comptime unreachable;
    }

    /// Converts the contents of a directory into a Nix archive. The directory passed must be
    /// opened with iteration capabilities.
    pub fn fromDirectory(allocator: std.mem.Allocator, root: std.fs.Dir) !NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
            .name_pool = undefined,
        };
        self.name_pool = .init(self.arena.allocator());
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        const root_node = try self.pool.create();
        root_node.* = .{
            .entry = null,
            .data = .{ .directory = null },
        };
        self.root = root_node;

        const Iterator = struct {
            iterator: std.fs.Dir.Iterator, // holds the directory
            object: *Object,
        };

        var iters_buf: [256]Iterator = undefined;

        var iters: std.ArrayListUnmanaged(Iterator) = .initBuffer(&iters_buf);

        iters.appendAssumeCapacity(.{
            .iterator = root.iterate(),
            .object = root_node,
        });

        errdefer if (iters.items.len > 1) for (iters.items[1..]) |*x| x.iterator.dir.close();

        while (iters.items.len != 0) {
            var cur = &iters.items[iters.items.len - 1];
            const entry = try cur.iterator.next();

            if (entry) |e| {
                const next = try self.pool.create();
                next.*.entry = .{
                    .parent = cur.object,
                    .name = try self.arena.allocator().dupe(u8, e.name),
                };
                switch (e.kind) {
                    .directory => {
                        next.*.data = .{ .directory = null };
                        var child = try cur.iterator.dir.openDir(e.name, .{ .iterate = true });
                        iters.appendBounded(.{
                            .iterator = child.iterate(),
                            .object = next,
                        }) catch return error.NestedTooDeep;
                    },
                    .sym_link => {
                        next.*.data = .{ .symlink = undefined };
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        const link = try cur.iterator.dir.readLink(e.name, &buf);
                        next.data.symlink = try self.arena.allocator().dupe(u8, link);
                    },
                    else => {
                        next.*.data = .{ .file = undefined };

                        var file = try cur.iterator.dir.openFile(e.name, .{});
                        defer file.close();

                        const stat = try file.stat();

                        var fr = file.reader(&.{});

                        var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
                        while (try fr.interface.streamRemaining(&aw.writer) != 0) {}

                        next.data.file = .{
                            .contents = aw.toOwnedSlice() catch unreachable,
                            .is_executable = stat.mode & 1 == 1,
                        };
                    },
                }
                try cur.object.insertChild(next);
            } else {
                if (iters.items.len > 1) cur.iterator.dir.close();
                _ = iters.pop().?;
            }
        }

        return self;
    }

    /// Creates a NAR archive containing a single file given its contents.
    pub fn fromFileContents(
        allocator: std.mem.Allocator,
        contents: []const u8,
        is_executable: bool,
    ) std.mem.Allocator.Error!NixArchive {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var pool = std.heap.MemoryPool(Object).init(arena.allocator());
        errdefer arena.deinit();

        const copy = try arena.allocator().dupe(u8, contents);

        const node = try pool.create();

        node.* = .{
            .entry = null,
            .data = .{ .file = .{ .is_executable = is_executable, .contents = copy } },
        };

        return .{
            .arena = arena,
            .pool = pool,
            .root = node,
            .name_pool = .init(arena.allocator()),
        };
    }

    /// Creates a NAR archive containing a single symlink given its target.
    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []const u8,
    ) std.mem.Allocator.Error!NixArchive {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var pool = std.heap.MemoryPool(Object).init(arena.allocator());
        errdefer arena.deinit();

        const node = try pool.create();

        const copy = try arena.allocator().dupe(u8, target);

        node.* = .{
            .entry = null,
            .data = .{ .symlink = copy },
        };

        return .{
            .arena = arena,
            .pool = pool,
            .root = node,
            .name_pool = .init(arena.allocator()),
        };
    }

    /// Serialize a NixArchive into the writer.
    pub fn toWriter(self: NixArchive, writer: *std.Io.Writer) !void {
        var node = self.root;

        try writeTokens(writer, &.{.magic});

        loop: while (true) {
            if (node.entry != null) {
                try writeTokens(writer, &.{.directory_entry});
                try writeStr(writer, node.entry.?.name);
                try writeTokens(writer, &.{.directory_entry_inner});
            }

            switch (node.data) {
                .directory => |child| {
                    try writeTokens(writer, &.{.directory});
                    if (child) |next| {
                        node = next;
                        continue;
                    }
                },
                .file => |data| {
                    try writeTokens(writer, &.{.file});
                    if (data.is_executable) try writeTokens(writer, &.{.executable_file});
                    try writeTokens(writer, &.{.file_contents});
                    try writeStr(writer, data.contents);
                },
                .symlink => |link| {
                    try writeTokens(writer, &.{.symlink});
                    try writeStr(writer, link);
                },
            }
            if (node.entry != null) try writeTokens(writer, &.{.directory_entry_end});
            while ((node.entry orelse break :loop).next == null) {
                node = node.entry.?.parent;
                if (node.entry != null) try writeTokens(writer, &.{.directory_entry_end});
            } else node = node.entry.?.next.?;
        }
        try writeTokens(writer, &.{.archive_end});
    }

    /// Unpacks a Nix archive into a directory.
    pub fn toDirectory(self: NixArchive, target_dir: std.fs.Dir) !void {
        if (self.root.data.directory == null) return;

        var item_buf: [256]std.fs.Dir = undefined;
        var items: std.ArrayListUnmanaged(std.fs.Dir) = .initBuffer(&item_buf);
        defer if (items.items.len > 1) for (items.items[1..]) |*dir| dir.close();
        items.appendAssumeCapacity(target_dir);

        var current_node = self.root.data.directory.?;

        const lastItem = struct {
            fn f(array: anytype) ?@TypeOf(array.items[0]) {
                return if (array.items.len == 0) null else array.items[array.items.len - 1];
            }
        }.f;

        while (lastItem(items)) |cwd| {
            if (std.mem.indexOfScalar(u8, current_node.entry.?.name, 0) != null)
                return error.MaliciousArchive;
            switch (current_node.data) {
                .file => |metadata| {
                    try cwd.writeFile(.{
                        .sub_path = current_node.entry.?.name,
                        .data = metadata.contents,
                        .flags = .{ .mode = if (metadata.is_executable) 0o777 else 0o666 },
                    });
                },
                .symlink => |target| {
                    cwd.deleteFile(current_node.entry.?.name) catch {};
                    try cwd.symLink(target, current_node.entry.?.name, .{});
                },
                .directory => |child| {
                    if (std.mem.eql(u8, current_node.entry.?.name, "..") or
                        std.mem.containsAtLeastScalar(u8, current_node.entry.?.name, 1, '/'))
                        return error.MaliciousArchive;
                    if (std.mem.eql(u8, ".", current_node.entry.?.name))
                        return error.MaliciousArchive;
                    if (std.mem.indexOfScalar(u8, current_node.entry.?.name, 0) != null)
                        return error.MaliciousArchive;
                    try cwd.makeDir(current_node.entry.?.name);
                    if (child) |node| {
                        const next = items.addOneBounded() catch return error.NestedTooDeep;
                        errdefer _ = items.pop().?;

                        next.* = try cwd.openDir(current_node.entry.?.name, .{});
                        current_node = node;
                        continue;
                    }
                },
            }
            while ((current_node.entry orelse return).next == null) {
                current_node = current_node.entry.?.parent;
                var dir = items.pop().?;
                if (current_node.entry != null) dir.close();
            }
            current_node = current_node.entry.?.next.?;
        }
    }

    /// Takes a directory and serializes it as a Nix Archive into `writer`. This is faster and more
    /// memory-efficient than calling `fromDirectory` followed by `pack`.
    pub fn packDirectory(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        writer: *std.Io.Writer,
    ) !void {
        // Idea: Make a list of nodes sorted by least depth to most depth, followed by names sorted
        // in reverse. Reading the next node is as easy as popping. `dir_indicies` is to keep track
        // of where the contents of each directory end.

        var node_names: std.heap.MemoryPoolAligned([std.fs.max_name_bytes]u8, .@"64") = .init(allocator);
        defer node_names.deinit();

        var nodes: std.MultiArrayList(struct {
            kind: std.meta.Tag(Object.Data),
            name: []u8,
        }) = .empty;
        defer nodes.deinit(allocator);

        try nodes.ensureUnusedCapacity(allocator, 4096);

        var dirs: std.ArrayList(std.fs.Dir.Iterator) = try .initCapacity(allocator, 1);
        defer dirs.deinit(allocator);
        errdefer for (dirs.items[1..]) |*d| d.dir.close();

        try dirs.ensureUnusedCapacity(allocator, 16);

        var dir_indicies: std.ArrayList(usize) = .empty;
        defer dir_indicies.deinit(allocator);

        try dir_indicies.ensureUnusedCapacity(allocator, 16);

        dirs.appendAssumeCapacity(dir.iterate());

        const Scan = enum { scan_directory, print };

        try writeTokens(writer, &.{ .magic, .directory });

        loop: switch (Scan.scan_directory) {
            .scan_directory => {
                try dir_indicies.append(allocator, nodes.len);
                const last_iter = &dirs.items[dirs.items.len - 1];
                while (try last_iter.next()) |entry| {
                    try nodes.append(allocator, .{
                        .name = blk: {
                            var name = try node_names.create();
                            @memcpy(name[0..entry.name.len], entry.name);
                            break :blk name[0..entry.name.len];
                        },
                        .kind = switch (entry.kind) {
                            .sym_link => .symlink,
                            .directory => .directory,
                            else => .file,
                        },
                    });
                }
                nodes.sortSpanUnstable(dir_indicies.getLast(), nodes.len, struct {
                    names: []const []const u8,

                    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                        return std.mem.order(
                            u8,
                            ctx.names[a],
                            ctx.names[b],
                        ) == .gt;
                    }
                }{ .names = nodes.items(.name) });
                continue :loop .print;
            },
            .print => {
                while (nodes.len > dir_indicies.getLast() and nodes.len > 0) {
                    const cur = nodes.pop().?;
                    const name = cur.name;
                    defer node_names.destroy(@ptrCast(@alignCast(name)));

                    try writeTokens(writer, &.{.directory_entry});
                    try writeStr(writer, name);
                    try writeTokens(writer, &.{.directory_entry_inner});
                    switch (cur.kind) {
                        .directory => {
                            try writeTokens(writer, &.{.directory});
                            try dirs.ensureUnusedCapacity(allocator, 1);
                            const d = try dirs.getLast().dir.openDir(name, .{ .iterate = true });
                            dirs.appendAssumeCapacity(d.iterateAssumeFirstIteration());
                            continue :loop .scan_directory;
                        },
                        .file => {
                            try writeTokens(writer, &.{.file});
                            var file = try dirs.getLast().dir.openFile(name, .{});
                            defer file.close();
                            if (try file.mode() & 0o111 != 0)
                                try writeTokens(writer, &.{.executable_file});
                            try writeTokens(writer, &.{.file_contents});

                            var fr = file.reader(&.{});

                            if (fr.getSize()) |size| {
                                try writer.writeInt(u64, size, .little);
                                var left = size;
                                while (left != 0) {
                                    const read = try writer.sendFileAll(&fr, .limited64(size));
                                    left -= read;
                                    if (read == 0 and left != 0) return error.EndOfStream;
                                }
                                try writePadding(writer, size);
                            } else |_| {
                                @branchHint(.unlikely);
                                var aw: std.Io.Writer.Allocating = .init(allocator);
                                defer aw.deinit();

                                try aw.ensureUnusedCapacity(fr.interface.buffer.len);

                                while (try aw.writer.sendFileAll(&fr, .unlimited) != 0) {}
                                const size = aw.writer.buffered().len;
                                try writer.writeInt(u64, size, .little);
                                try writer.writeAll(aw.writer.buffered());
                                try writePadding(writer, size);
                            }
                        },
                        .symlink => {
                            try writeTokens(writer, &.{.symlink});
                            var buf: [std.fs.max_path_bytes]u8 = undefined;
                            const link = dirs.getLast().dir.readLink(name, &buf) catch |e|
                                switch (e) {
                                    error.NameTooLong => unreachable,
                                    else => return e,
                                };
                            try writeStr(writer, link);
                        },
                    }

                    try writeTokens(writer, &.{.directory_entry_end});
                } else {
                    if (dirs.items.len == 1) break :loop;
                    try writeTokens(writer, &.{.directory_entry_end});
                    _ = dir_indicies.pop().?;
                    var d = dirs.pop().?;
                    d.dir.close();
                    continue :loop .print;
                }
            },
        }

        try writeTokens(writer, &.{.archive_end});
    }

    /// Takes a reader and serializes its contents as a Nix Archive of a file into `writer`. This is
    /// faster and more memory-efficient than calling `fromFileContents` followed by `pack`.
    pub fn packFile(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        executable: bool,
        size: ?u64,
    ) !void {
        try writeTokens(writer, &.{ .magic, .file });
        if (executable) try writeTokens(writer, &.{.executable_file});
        try writeTokens(writer, &.{.file_contents});

        const sz = blk: {
            if (size) |s| {
                try writer.writeInt(u64, s, .little);

                try reader.streamExact64(writer, s);

                break :blk s;
            } else {
                var aw = std.Io.Writer.Allocating.init(allocator);
                defer aw.deinit();

                try aw.ensureUnusedCapacity(reader.buffer.len);

                const s = s: {
                    var total: u64 = 0;
                    var read = try reader.streamRemaining(&aw.writer);
                    while (read != 0) {
                        total += read;
                        read = try reader.streamRemaining(&aw.writer);
                    }
                    break :s total;
                };
                try writer.writeInt(u64, s, .little);
                try writer.writeAll(aw.written());
                break :blk s;
            }
        };
        try writePadding(writer, sz);

        try writeTokens(writer, &.{.archive_end});
    }

    pub fn packSymlink(target: []const u8, writer: *std.Io.Writer) !void {
        try writeTokens(writer, &.{ .magic, .symlink });
        try writeStr(writer, target);
        try writeTokens(writer, &.{.archive_end});
    }

    pub fn unpackDirectory(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        out_dir: std.fs.Dir,
        file_out_buffer: []u8,
    ) !void {
        std.debug.assert(reader.buffer.len >= std.fs.max_path_bytes);

        var currents: std.MultiArrayList(struct {
            name_buf: [std.fs.max_name_bytes]u8 = undefined,
            last_name_len: ?Name = null,
            dir: std.fs.Dir,
        }) = .empty;
        defer currents.deinit(allocator);

        defer if (currents.len > 1) for (currents.items(.dir)[1..]) |*d| d.close();

        try currents.append(allocator, .{ .dir = out_dir });

        const State = enum { directory_entry, directory, file, symlink, end, leave_directory };

        expectToken(reader, .magic) catch |e| switch (e) {
            error.InvalidToken => return error.NotANar,
            error.ReadFailed => return error.ReadFailed,
        };

        expectToken(reader, .directory) catch |e| switch (e) {
            error.InvalidToken => return error.WrongArchiveType,
            error.ReadFailed => return error.ReadFailed,
        };

        state: switch (State.directory_entry) {
            .directory_entry => {
                expectToken(reader, .directory_entry) catch |e| switch (e) {
                    error.InvalidToken => continue :state .leave_directory,
                    else => return e,
                };

                const name = try takeName(reader);

                if (std.mem.indexOfScalar(u8, name, 0) != null or
                    std.mem.indexOfScalar(u8, name, '/') != null or
                    std.mem.eql(u8, name, ".") or
                    std.mem.eql(u8, name, ".."))
                {
                    return error.MaliciousArchive;
                }

                const cur = currents.get(currents.len - 1);
                if (cur.last_name_len) |l| switch (std.mem.order(u8, cur.name_buf[0..l], name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => {
                        return error.WrongDirectoryOrder;
                    },
                };

                @memcpy(currents.items(.name_buf)[currents.len - 1][0..name.len], name);

                currents.items(.last_name_len)[currents.len - 1] = @intCast(name.len);

                try expectToken(reader, .directory_entry_inner);

                const file_string = getTokenString(.file);
                const directory_string = getTokenString(.directory);
                const symlink_string = getTokenString(.symlink);
                if (std.mem.eql(u8, file_string, try reader.peek(file_string.len)))
                    continue :state .file
                else if (std.mem.eql(u8, directory_string, try reader.peek(directory_string.len)))
                    continue :state .directory
                else if (std.mem.eql(u8, symlink_string, try reader.peek(symlink_string.len)))
                    continue :state .symlink
                else
                    return error.InvalidToken;
            },
            .file => {
                expectToken(reader, .file) catch unreachable;
                const exec_token = getTokenString(.executable_file);
                const is_executable = std.mem.eql(u8, try reader.peek(exec_token.len), exec_token);
                if (is_executable) reader.toss(exec_token.len);

                try expectToken(reader, .file_contents);

                const size = try reader.takeInt(u64, .little);

                const cur = currents.get(currents.len - 1);

                var file = try cur.dir.createFile(
                    cur.name_buf[0..cur.last_name_len.?],
                    .{ .mode = if (is_executable) 0o777 else 0o666 },
                );
                defer file.close();

                var fw = file.writer(file_out_buffer);
                try reader.streamExact64(&fw.interface, size);
                try fw.interface.flush();

                if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
                    return error.InvalidToken;

                try expectToken(reader, .directory_entry_end);

                continue :state .directory_entry;
            },
            .symlink => {
                expectToken(reader, .symlink) catch unreachable;

                const size = std.math.cast(Target, try reader.takeInt(u64, .little)) orelse
                    return error.NameTooLarge;
                switch (size) {
                    0 => return error.NameTooSmall,
                    1...std.fs.max_path_bytes => {},
                    else => return error.NameTooLarge,
                }

                const cur = currents.get(currents.len - 1);
                const target = try reader.take(size);
                if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidToken;

                cur.dir.symLink(target, cur.name_buf[0..cur.last_name_len.?], .{}) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };

                if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
                    return error.InvalidToken;

                try expectToken(reader, .directory_entry_end);

                continue :state .directory_entry;
            },
            .directory => {
                expectToken(reader, .directory) catch unreachable;

                const cur = currents.get(currents.len - 1);

                const entry_string = getTokenString(.directory_entry);

                const has_children = std.mem.eql(u8, try reader.peek(entry_string.len), entry_string);

                try currents.ensureUnusedCapacity(allocator, 1);

                const child_name = cur.name_buf[0..cur.last_name_len.?];

                cur.dir.makeDir(child_name) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
                if (has_children) {
                    const child = try cur.dir.openDir(child_name, .{});
                    currents.appendAssumeCapacity(.{ .dir = child });
                } else try expectToken(reader, .directory_entry_end);
                continue :state .directory_entry;
            },
            .leave_directory => {
                if (currents.len == 1)
                    continue :state .end
                else {
                    try expectToken(reader, .directory_entry_end);
                    var cur = currents.pop().?;
                    cur.dir.close();
                    continue :state .directory_entry;
                }
            },
            .end => {
                try expectToken(reader, .archive_end);
                return;
            },
        }
        comptime unreachable;
    }

    /// Reads a Nix archive containing a single file from the reader and writes it to the writer.
    /// Returns whether the file is executable. This is faster and more memory-efficient than calling
    /// `fromReader` followed by `pack`.
    pub fn unpackFile(reader: *std.Io.Reader, writer: *std.Io.Writer) !bool {
        expectToken(reader, .magic) catch |e| switch (e) {
            error.InvalidToken => return error.NotANar,
            error.ReadFailed => return e,
        };

        try expectToken(reader, .file);

        const exec_token = getTokenString(.executable_file);

        const is_executable = if (std.mem.eql(u8, try reader.peek(exec_token.len), exec_token)) blk: {
            reader.toss(exec_token.len);
            break :blk true;
        } else false;

        try expectToken(reader, .file_contents);

        const size = try reader.takeInt(u64, .little);
        try reader.streamExact64(writer, size);

        if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
            return error.InvalidToken;

        try expectToken(reader, .archive_end);
        return is_executable;
    }

    /// Reads a Nix archive containing a single symlink and returns the target. This is faster and
    /// more memory-efficient than calling `fromReader`.
    pub fn unpackSymlink(reader: *std.Io.Reader, buffer: *[std.fs.max_path_bytes]u8) ![]u8 {
        expectToken(reader, .magic) catch |e| switch (e) {
            error.InvalidToken => return error.NotANar,
            error.ReadFailed => return e,
        };

        try expectToken(reader, .symlink);

        const size = std.math.cast(Target, try reader.takeInt(u64, .little)) orelse
            return error.NameTooLarge;
        switch (size) {
            0 => return error.NameTooSmall,
            1...std.fs.max_path_bytes => {},
            else => return error.NameTooLarge,
        }

        @memcpy(buffer[0..size], try reader.take(size));

        if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
            return error.InvalidToken;

        try expectToken(reader, .archive_end);
        return buffer[0..size];
    }

    /// Pumps the contents of a file in the archive via a reader into the writer without fillowing
    /// symlinks. Returns whether the file was executable. If you want to follow symlinks, use
    /// `NixArchive.fromReader` followed by `subPath`. Asserts the reader's buffer contains at least
    /// `@max(std.fs.max_name_bytes, std.fs.max_path_bytes)` bytes.
    pub fn unpackSubFile(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        path: []const u8,
    ) !bool {
        std.debug.assert(reader.buffer.len >= @max(std.fs.max_path_bytes, std.fs.max_name_bytes));

        var parts: std.ArrayList([]const u8) = .empty;
        try parts.ensureTotalCapacity(allocator, 1 + std.mem.count(u8, path, "/"));
        defer parts.deinit(allocator);

        var names: std.MultiArrayList(struct { name: [std.fs.max_name_bytes]u8, len: Name }) = .empty;
        try names.ensureTotalCapacity(allocator, 64);
        defer names.deinit(allocator);

        normalizePath(&parts, path);

        var skip_depth: u64 = 0;

        const State = enum {
            start,
            take_file,
            take_directory,
            skip_file,
            skip_symlink,
            skip_directory,
            object_type_take,
            object_type_skip,
            entry_take,
            entry_skip,
            next_take,
            next_skip,
        };

        state: switch (State.start) {
            .start => {
                expectToken(reader, .magic) catch |e| switch (e) {
                    error.InvalidToken => return error.NotANar,
                    else => return e,
                };

                if (try takeToken(reader, .directory)) {
                    if (parts.items.len == 0) return error.IsDir;
                    names.appendAssumeCapacity(.{
                        .name = undefined,
                        .len = 0,
                    });
                    continue :state .entry_take;
                } else if (try takeToken(reader, .file))
                    continue :state if (parts.items.len == 0) .take_file else return error.Symlink
                else if (try takeToken(reader, .symlink))
                    return error.IsSymlink;
                unreachable;
            },
            .object_type_skip => {
                if (try takeToken(reader, .directory))
                    continue :state .skip_directory
                else if (try takeToken(reader, .file))
                    continue :state .skip_file
                else if (try takeToken(reader, .symlink))
                    continue :state .skip_symlink
                else
                    return error.InvalidToken;
            },
            .take_file => {
                const executable = try takeToken(reader, .executable_file);
                try expectToken(reader, .file_contents);
                const len = try reader.takeInt(u64, .little);
                try reader.streamExact64(writer, len);
                return executable; // Skip processing the rest of the archive
            },
            .take_directory => {
                if (names.len == parts.items.len) return error.IsDir;
                names.appendAssumeCapacity(.{
                    .name = undefined,
                    .len = 0,
                });
                continue :state .entry_take;
            },
            .skip_file => {
                _ = try takeToken(reader, .executable_file);
                try expectToken(reader, .file_contents);
                const len = try reader.takeInt(u64, .little);
                try reader.discardAll64(len);

                if (!std.mem.allEqual(u8, try reader.take(padding(len)), 0))
                    return error.InvalidPadding;

                continue :state if (skip_depth == 0) .next_take else .next_skip;
            },
            .skip_symlink => {
                const len = try reader.takeInt(u64, .little);
                if (len == 0) return error.TargetTooSmall;
                if (len > std.fs.max_path_bytes) return error.TargetTooLarge;
                try reader.discardAll64(len);

                if (!std.mem.allEqual(u8, try reader.take(padding(len)), 0))
                    return error.InvalidPadding;

                continue :state if (skip_depth == 0) .next_take else .next_skip;
            },
            .skip_directory => {
                if (try peekToken(reader, .directory_entry_end))
                    continue :state if (skip_depth == 0) .next_take else .next_skip;

                skip_depth += 1;

                try names.append(allocator, .{
                    .name = undefined,
                    .len = 0,
                });

                continue :state .entry_skip;
            },
            .object_type_take => {
                if (try takeToken(reader, .directory))
                    continue :state .take_directory
                else if (try takeToken(reader, .file))
                    continue :state .take_file
                else if (try takeToken(reader, .symlink))
                    return error.Symlink;

                return error.InvalidToken;
            },
            .entry_take => {
                //std.debug.print("Taking.\n", .{});
                if (names.len == 0 and try peekToken(reader, .archive_end)) return error.NoSuchFile;
                try expectToken(reader, .directory_entry);

                const name = try takeName(reader);
                //std.debug.print("name = {s}\n", .{name});

                const name_bufs = names.items(.name);
                const name_lens = names.items(.len);
                const prev = name_bufs[names.len - 1][0..name_lens[names.len - 1]];

                switch (std.mem.order(u8, prev, name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                }
                @memcpy(name_bufs[names.len - 1][0..name.len], name);
                name_lens[names.len - 1] = @intCast(name.len);

                try expectToken(reader, .directory_entry_inner);

                switch (std.mem.order(u8, name, parts.items[names.len - 1])) {
                    .lt => continue :state .object_type_skip,
                    .eq => continue :state .object_type_take,
                    .gt => return error.NoSuchFile,
                }
            },
            .entry_skip => {
                //std.debug.print("Skipping.\n", .{});
                if (names.len == 0 and try peekToken(reader, .archive_end)) return error.NoSuchFile;
                try expectToken(reader, .directory_entry);

                const name = try takeName(reader);
                //std.debug.print("name = {s}, depth = {}\n", .{name, skip_depth});

                const name_bufs = names.items(.name);
                const name_lens = names.items(.len);
                const prev = name_bufs[names.len - 1][0..name_lens[names.len - 1]];

                switch (std.mem.order(u8, prev, name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                }
                @memcpy(name_bufs[names.len - 1][0..name.len], name);
                name_lens[names.len - 1] = @intCast(name.len);

                try expectToken(reader, .directory_entry_inner);

                continue :state .object_type_skip;
            },
            .next_take => {
                std.debug.assert(skip_depth == 0);
                try expectToken(reader, .directory_entry_end);
                if (try peekToken(reader, .directory_entry_end)) return error.NoSuchFile;
                continue :state .entry_take;
            },
            .next_skip => {
                std.debug.assert(skip_depth != 0);
                try expectToken(reader, .directory_entry_end);
                while (try takeToken(reader, .directory_entry_end)) {
                    _ = names.pop();
                    skip_depth -= 1;
                    if (skip_depth == 0) continue :state .entry_take;
                }
                continue :state .entry_skip;
            },
        }

        comptime unreachable;
    }

    pub fn deinit(self: *NixArchive) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The array list must reserve at least `1 + std.mem.count(u8, path, "/")` items
fn normalizePath(out: *std.ArrayList([]const u8), path: []const u8) void {
    var iter = std.mem.splitScalar(u8, path, '/');

    var cur: ?[]const u8 = iter.first();

    while (cur) |c| : (cur = iter.next()) {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            _ = out.pop();
            continue;
        }
        out.appendAssumeCapacity(c);
    }
}

const Token = enum {
    magic,
    archive_end,
    directory,
    file,
    symlink,
    executable_file,
    file_contents,
    directory_entry,
    directory_entry_inner,
    directory_entry_end,
};

const token_map = std.StaticStringMap(Token).initComptime(.{
    .{ str("nix-archive-1") ++ str("("), .magic },
    .{ str(")"), .archive_end },
    .{ str("type") ++ str("directory"), .directory },
    .{ str("type") ++ str("regular"), .file },
    .{ str("type") ++ str("symlink") ++ str("target"), .symlink },
    .{ str("executable") ++ str(""), .executable_file },
    .{ str("contents"), .file_contents },
    .{ str("entry") ++ str("(") ++ str("name"), .directory_entry },
    .{ str(")") ++ str(")"), .directory_entry_end },
    .{ str("node") ++ str("("), .directory_entry_inner },
});

inline fn getTokenString(comptime value: Token) []const u8 {
    comptime {
        const values = token_map.values();
        const index = std.mem.indexOfScalar(Token, values, value).?;

        return token_map.keys()[index];
    }
}

fn takeToken(reader: *std.Io.Reader, comptime token: Token) error{ReadFailed}!bool {
    return if (expectToken(reader, token)) |_| true else |e| switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.InvalidToken => false,
    };
}

fn peekToken(reader: *std.Io.Reader, comptime token: Token) !bool {
    const taken = reader.peek(getTokenString(token).len) catch |e| switch (e) {
        error.EndOfStream => return false,
        error.ReadFailed => return error.ReadFailed,
    };

    return std.mem.eql(u8, getTokenString(token), taken);
}

fn expectToken(reader: *std.Io.Reader, comptime token: Token) !void {
    return if (peekToken(reader, token)) |r| switch (r) {
        true => {
            reader.toss(getTokenString(token).len);
            //std.debug.print("Got token {t}\n", .{token});
        },
        false => error.InvalidToken,
    } else |e| switch (e) {
        error.ReadFailed => error.ReadFailed,
    };
}

fn writeTokens(writer: *std.Io.Writer, comptime tokens: []const Token) !void {
    comptime var concatenated: []const u8 = "";

    comptime {
        for (tokens) |token| concatenated = concatenated ++ getTokenString(token);
    }

    try writer.writeAll(concatenated);
}

fn takeName(reader: *std.Io.Reader) ![]u8 {
    const len = std.math.cast(Name, try reader.takeInt(u64, .little)) orelse
        return error.NameTooLarge;
    if (len == 0) return error.NameTooSmall;
    if (len > std.fs.max_name_bytes) return error.NameTooLarge;

    const read = try reader.take(std.mem.alignForward(Name, len, 8));

    if (!std.mem.allEqual(u8, read[len..], 0)) return error.InvalidPadding;

    return read[0..len];
}

fn takeTarget(reader: *std.Io.Reader) ![]u8 {
    const len = std.math.cast(Target, try reader.takeInt(u64, .little)) orelse
        return error.TargetTooLarge;

    if (len == 0) return error.TargetTooSmall;
    if (len > std.fs.max_path_bytes) return error.TargetTooLarge;

    const read = try reader.take(std.mem.alignForward(Target, len, 8));

    if (!std.mem.allEqual(u8, read[len..], 0)) return error.InvalidPadding;

    return read[0..len];
}

fn writeStr(writer: *std.Io.Writer, string: []const u8) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, string.len, .little);

    const zeroes: [7]u8 = .{0} ** 7;

    try writer.print("{s}{s}{s}", .{ &buffer, string, zeroes[0 .. (8 - string.len % 8) % 8] });
}

fn writePadding(writer: *std.Io.Writer, size: u64) !void {
    try writer.splatByteAll(0, padding(size));
}

fn padding(size: u64) u3 {
    return @truncate(-%size);
}

fn str(comptime string: anytype) []const u8 {
    comptime {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, string.len, .little);

        const zeroes: [7]u8 = .{0} ** 7;
        return buffer ++ string ++ (if (string.len % 8 == 0) [0]u8{} else zeroes[0 .. (8 - string.len % 8) % 8]);
    }
}

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}

test "single file" {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(@constCast(@embedFile("tests/README.nar")));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    try std.testing.expectEqualStrings(@embedFile("tests/README.out"), data.root.data.file.contents);
}

test "directory containing a single file" {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(@constCast(@embedFile("tests/hello.nar")));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    const dir = data.root;
    const file = dir.data.directory.?;
    try std.testing.expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.file.contents);
    try std.testing.expectEqualStrings("main.zig", file.entry.?.name);
}

test "a file, a directory, and some more files" {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(@constCast(@embedFile("tests/dir-and-files.nar")));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try std.testing.expectEqualStrings("dir", dir.entry.?.name);

    const file1 = dir.entry.?.next.?;
    try std.testing.expectEqual(file1.entry.?.next, null);
    try std.testing.expectEqualStrings("file1", file1.entry.?.name);
    try std.testing.expectEqual(false, file1.data.file.is_executable);
    try std.testing.expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try std.testing.expectEqualStrings("file2", file2.entry.?.name);
    try std.testing.expectEqual(true, file2.data.file.is_executable);
    try std.testing.expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.entry.?.next.?;
    try std.testing.expectEqual(false, file3.data.file.is_executable);
    try std.testing.expectEqualStrings("file3", file3.entry.?.name);
    try std.testing.expectEqualStrings("nevermind\n", file3.data.file.contents);
    try std.testing.expectEqual(null, file3.entry.?.next);
}

test "a symlink" {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(@constCast(@embedFile("tests/symlink.nar")));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    try std.testing.expectEqualStrings("README.out", data.root.data.symlink);
}

test "nar from dir-and-files" {
    const allocator = std.testing.allocator;

    var root = try std.fs.cwd().openDir(tests_path ++ "/dir-and-files", .{ .iterate = true });
    defer root.close();

    var data = try NixArchive.fromDirectory(allocator, root);
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try std.testing.expectEqualStrings("dir", dir.entry.?.name);

    const file1 = dir.entry.?.next.?;
    try std.testing.expectEqual(null, file1.entry.?.next);
    try std.testing.expectEqualStrings("file1", file1.entry.?.name);
    try std.testing.expectEqual(false, file1.data.file.is_executable);
    try std.testing.expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try std.testing.expectEqualStrings("file2", file2.entry.?.name);
    try std.testing.expectEqual(true, file2.data.file.is_executable);
    try std.testing.expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.entry.?.next.?;
    try std.testing.expectEqual(false, file3.data.file.is_executable);
    try std.testing.expectEqualStrings("file3", file3.entry.?.name);
    try std.testing.expectEqualStrings("nevermind\n", file3.data.file.contents);
    try std.testing.expectEqual(null, file3.entry.?.next);
}

test "empty directory" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/empty", .{ .iterate = true });
    defer root.close();

    var data = try NixArchive.fromDirectory(allocator, root);
    defer data.deinit();

    try std.testing.expectEqual(null, data.root.data.directory);
}

test "nar to directory to nar" {
    const allocator = std.testing.allocator;

    var reader: std.Io.Reader = .fixed(@constCast(@embedFile("tests/dir-and-files.nar")));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    const expected = @embedFile("tests/dir-and-files.nar");

    var buffer: [2 * expected.len]u8 = undefined;

    var writer: std.Io.Writer = .fixed(&buffer);

    try data.toWriter(&writer);

    try std.testing.expectEqualSlices(u8, expected, writer.buffered());
}

test "more complex" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/complex/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/complex", .{ .iterate = true });
    defer root.close();

    const expected = @embedFile("tests/complex.nar") ** 3 ++
        @embedFile("tests/complex_empty.nar") ** 2;

    var array_buf: [2 * expected.len]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&array_buf);
    const writer = &fixed;

    {
        try NixArchive.packDirectory(allocator, root, writer);

        var archive = try NixArchive.fromDirectory(allocator, root);
        defer archive.deinit();

        try archive.toWriter(writer);

        const contents: []u8 = @constCast(@embedFile("tests/complex.nar"));

        var reader: std.Io.Reader = .fixed(contents);

        var other_archive = try NixArchive.fromReader(allocator, &reader, .{});
        defer other_archive.deinit();

        try other_archive.toWriter(writer);
    }
    {
        var empty = try root.openDir("empty", .{ .iterate = true });
        defer empty.close();

        try NixArchive.packDirectory(allocator, empty, writer);

        var archive = try NixArchive.fromDirectory(allocator, empty);
        defer archive.deinit();

        try archive.toWriter(writer);
    }

    // TODO: Add more packs and froms
    try std.testing.expectEqualSlices(u8, expected, writer.buffered());
}
