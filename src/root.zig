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

    pub const min_buffer_size = @max(
        @max(std.fs.max_path_bytes, std.fs.max_name_bytes) +
            Token.toString(.directory_entry_end).len,
        Token.toString(.magic).len + @max(
            Token.toString(.directory).len,
            Token.toString(.file).len,
            Token.toString(.executable_file).len,
            Token.toString(.symlink).len,
        ),
    );

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

        pub const Data = union(Kind) {
            file: []u8,
            executable_file: []u8,
            symlink: []u8,
            directory: ?*Object,
        };

        pub const Kind = enum {
            file,
            executable_file,
            symlink,
            directory,

            pub fn isFile(k: Kind) bool {
                return switch (k) {
                    .file, .executable_file => true,
                    .symlink, .directory => false,
                };
            }

            pub fn toToken(k: Kind) Token {
                return switch (k) {
                    .file => .file,
                    .executable_file => .executable_file,
                    .symlink => .symlink,
                    .directory => .directory,
                };
            }
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
                    .file, .executable_file => if (parts.items.len != 0) return error.NotDir,
                    .symlink => |target| {
                        if (std.mem.startsWith(u8, target, "/")) return error.PathOutsideArchive;
                    },
                }
            }
            return cur;
        }
    };

    /// A higher-level directory entry-based iterator built upon `Token`.
    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
    pub const UnpackIterator = struct {
        reader: *std.Io.Reader,
        names: Names,
        in_reader: bool = false,

        pub const Names = std.ArrayList(struct {
            name: [std.fs.max_name_bytes]u8,
            len: Name,
        });

        pub const PathSafety = enum { allow, deny };

        pub const Entry = struct {
            /// Invalidated upon `.skip` or `.take`
            name: []const u8,
            kind: Object.Kind,
        };

        pub fn init(reader: *std.Io.Reader) UnpackIterator {
            std.debug.assert(reader.buffer.len >= min_buffer_size);
            return .{
                .reader = reader,
                .names = .empty,
            };
        }

        pub fn deinit(iter: *UnpackIterator, allocator: std.mem.Allocator) void {
            iter.names.deinit(allocator);
            iter.* = undefined;
        }

        pub fn first(iter: *UnpackIterator) !Object.Kind {
            const kind = try peekType(iter.reader);
            Token.expect(iter.reader, .magic) catch unreachable;
            switch (kind) {
                inline else => |t| Token.expect(iter.reader, t.toToken()) catch unreachable,
            }
            return kind;
        }

        pub fn takeFile(iter: *UnpackIterator, buffer: []u8) Reader {
            std.debug.assert(!iter.in_reader);
            iter.in_reader = true;
            return .{
                .iter = &iter,
                .reader = .{
                    .buffer = buffer,
                    .vtable = &.{ .stream = stream },
                },
            };
        }

        pub fn takeSymlink(iter: *UnpackIterator, buffer: []u8) ![]u8 {
            const len = try iter.reader.takeInt(u64, .little);
            if (len > buffer.len) return error.Overflow;
            const ret = try iter.reader.readAll(buffer);
            if (!std.mem.allEqual(u8, try iter.reader.take(Token.padding(len)), 0))
                return error.InvalidPadding;
            if (iter.names.items.len > 0) try Token.expect(iter.reader, .directory_entry_end);
            return ret;
        }

        pub fn takeDirectory(iter: *UnpackIterator, allocator: std.mem.Allocator) !void {
            const child = try iter.names.addOne(allocator);
            child.len = 0;
        }

        /// Skip a file, returning its size.
        pub fn skipFile(iter: *UnpackIterator) !u64 {
            const size = try iter.reader.take(u64, .little);
            try iter.reader.discardAll64(size);

            if (!std.mem.allEqual(u8, try iter.reader.take(Token.padding(size)), 0))
                return error.InvalidPadding;

            if (iter.names.items.len > 0) try Token.expect(iter.reader, .directory_entry_end);
            return size;
        }

        /// Skip a symlink, returning its size.
        pub const skipSymlink = skipFile;

        pub fn skip(
            iter: *UnpackIterator,
            allocator: std.mem.Allocator,
            kind: Object.Kind,
            safety: PathSafety,
        ) !void {
            switch (kind) {
                .file, .executable_file => _ = try iter.skipFile(),
                .symlink => _ = try iter.skipSymlink(),
                .directory => {
                    const depth = iter.names.items.len;
                    try iter.enterDirectory(allocator);
                    while (iter.names.items.len != depth) if (try iter.next(safety)) |e|
                        switch (e.kind) {
                            .file, .executable_file => _ = try iter.skipFile(),
                            .symlink => _ = try iter.skipSymlink(),
                            .directory => try iter.enterDirectory(allocator),
                        };
                },
            }
        }

        /// Get the next entry within the current directory. `null` means leaving a directory.
        /// Name invalidated upon calling `skip`, `enterDirectory`, or `finish`.
        pub fn next(iter: *UnpackIterator, safety: PathSafety) !?Entry {
            std.debug.assert(iter.names.items.len != 0);
            if (try Token.take(iter.reader, .directory_entry)) {
                const name = try Token.takeName(iter.reader);
                const last = &iter.names.items[iter.names.items.len - 1];
                switch (std.mem.order(
                    u8,
                    iter.names.items[iter.names.items.len - 1].toString(),
                    name,
                )) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                }
                @memcpy(last[0..name.len], name);
                last.len = name.len;
                if (safety == .deny)
                    if (std.mem.indexOfScalar(u8, name, 0) != null or
                        std.mem.indexOfScalar(u8, name, '/') != null or
                        std.mem.eql(u8, name, ".") or
                        std.mem.eql(u8, name, ".."))
                        return error.ForbiddenName;

                try Token.expect(iter.reader, .directory_entry_inner);

                const kind: Object.Kind = if (try Token.take(iter.reader, .file))
                    .file
                else if (try Token.take(iter.reader, .executable_file))
                    .executable_file
                else if (try Token.take(iter.reader, .directory))
                    .directory
                else if (try Token.take(iter.reader, .symlink))
                    .symlink
                else
                    return error.InvalidToken;

                return .{
                    .name = last.name[0..last.len],
                    .kind = kind,
                };
            } else {
                iter.names.items.len -= 1;
                return null;
            }
        }

        /// Finish parsing the archive. This does not free the memory: call `.deinit` after.
        pub fn finish(self: *UnpackIterator, allocator: ?std.mem.Allocator) !void {
            while (self.names.items.len != 0) {
                if (try self.next(allocator.?)) |e| _ = try self.skip(allocator.?, e);
            }

            try Token.expect(self.reader, .archive_end);
        }
    };

    pub const PackIterator = struct {
        writer: *std.Io.Writer,
        names: UnpackIterator.Names,
        /// For the writer given by `.writer()`
        current_limit: ?u64,
        written: u64,
        file_writer: std.Io.Writer,

        pub const Entry = struct {
            name: []const u8,
            kind: Object.Kind,
        };

        pub fn init(writer: *std.Io.Writer) PackIterator {
            return .{
                .writer = writer,
                .names = .empty,
                .current_limit = null,
                .written = undefined,
                .file_writer = .{
                    .buffer = &.{},
                    .vtable = &.{ .drain = drain },
                },
            };
        }

        pub fn leaveDirectory(iter: *PackIterator) !void {
            try Token.write(iter.writer, &.{.directory_entry_end});
            iter.names.items.len -= 1;
        }

        pub fn finish(iter: *PackIterator) !void {
            while (iter.names.items.len > 0) try iter.leaveDirectory();
            try Token.write(iter.writer, &.{.archive_end});
        }

        pub fn deinit(iter: *PackIterator, allocator: std.mem.Allocator) void {
            iter.names.deinit(allocator);
            iter.* = undefined;
        }

        pub fn first(iter: *PackIterator, allocator: ?std.mem.Allocator, kind: std.meta.Tag(Object.Data)) !void {
            try Token.write(iter.writer, &.{.magic});
            switch (kind) {
                .file => try Token.write(iter.writer, &.{.file}),
                .executable_file => try Token.write(iter.writer, &.{.executable_file}),
                .directory => {
                    try Token.write(iter.writer, &.{.directory});
                    const first_layer = try iter.names.addOne(allocator.?);
                    first_layer.len = 0;
                },
                .symlink => try Token.write(iter.writer, &.{.symlink}),
            }
        }

        /// For symlinks and files, use `.write()` afterwards.
        pub fn next(iter: *PackIterator, allocator: std.mem.Allocator, entry: Entry) !void {
            std.debug.assert(iter.names.items.len > 0);
            if (iter.current_limit) |l| std.debug.assert(l == iter.written);
            if (entry.kind == .directory) try iter.names.ensureUnusedCapacity(allocator, 1);
            const prev = &iter.names.items[iter.names.items.len - 1];
            const prev_name = prev.name[0..prev.len];
            if (entry.name.len > std.fs.max_name_bytes) return error.NameTooLong;
            std.debug.assert(std.mem.order(u8, prev_name, entry.name) == .gt);
            @memcpy(prev.name[0..entry.name.len], entry.name);
            prev.len = @intCast(entry.name.len);

            try Token.write(iter.writer, &.{.directory_entry});
            try Token.writeStr(iter.writer, entry.name);
            try Token.write(iter.writer, &.{.directory_entry_inner});
            switch (entry.kind) {
                .directory => {
                    const next_layer = iter.names.addOneAssumeCapacity();
                    next_layer.len = 0;
                    try Token.write(iter.writer, &.{.directory});
                },
                .file => try Token.write(iter.writer, &.{.file}),
                .executable_file => try Token.write(iter.writer, &.{.executable_file}),
                .symlink => try Token.write(iter.writer, &.{.symlink}),
            }
        }

        pub fn write(iter: *PackIterator, len: u64) !*std.Io.Writer {
            std.debug.assert(iter.current_limit == null);
            try iter.writer.writeInt(u64, len, .little);
            iter.current_limit = len;
            iter.written = 0;
            return &iter.file_writer;
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
            const iter: *PackIterator = @fieldParentPtr("file_writer", w);
            if (iter.current_limit == null) return error.WriteFailed;

            const left = iter.current_limit.? - iter.written;
            var total: usize = 0;

            if (left == 0) {
                const l = iter.current_limit.?;
                try iter.writer.rebase(0, Token.toString(.directory_entry_end).len + Token.padding(l));
                Token.writePadding(iter.writer, l) catch unreachable;
                Token.write(iter.writer, &.{.directory_entry_end}) catch unreachable;
                iter.current_limit = null;
                iter.written = undefined;
                return error.WriteFailed;
            }

            for (data[0 .. data.len - 1], 0..) |s, i| {
                if (s.len + total > left) {
                    const amount_written = try iter.writer.writeVec(data[0 .. i - 1]);
                    iter.written += amount_written;
                    return amount_written;
                }
                total += s.len;
            } else {
                const last = data[data.len - 1];
                const amount_written = if (last.len == 0)
                    try iter.writer.writeVec(data[0..data.len -| 1])
                else
                    try iter.writer.writeSplat(data, @min(splat, (left - total) / last.len));
                iter.written += amount_written;
                return amount_written;
            }
        }
    };

    /// Returns the type of archive in the reader. Asserts the reader buffer holds at least
    /// `NixArchive.min_buffer_size` bytes.
    pub fn peekType(reader: *std.Io.Reader) !Object.Kind {
        std.debug.assert(reader.buffer.len >= min_buffer_size);
        reader.fillMore() catch {};

        if (!try Token.take(reader, .magic)) return error.NotANar;
        defer reader.seek -= Token.toString(.magic).len;

        if (try Token.peek(reader, .file))
            return .file
        else if (try Token.peek(reader, .directory))
            return .directory
        else if (try Token.peek(reader, .symlink))
            return .symlink
        else if (try Token.peek(reader, .executable_file))
            return .executable_file
        else
            return error.InvalidToken;
    }

    pub const FromReaderOptions = struct {
        /// The length of each file is always stored
        store_file_contents: bool = true,
    };

    pub const FromReaderError = std.mem.Allocator.Error || std.Io.Reader.StreamError || error{
        NotANar,
        InvalidToken,
        InvalidPadding,
        TargetTooSmall,
        TargetTooLarge,
        NameTooSmall,
        NameTooLarge,
        DuplicateObjectName,
        WrongDirectoryOrder,
        MaliciousArchive,
    };

    /// Returns a Nix archive from the given reader. Data after the end of the archive is not read.
    /// Asserts the reader's buffer holds at `NixArchive.min_buffer_size` bytes.
    pub fn fromReader(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        options: FromReaderOptions,
    ) FromReaderError!NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = .empty,
            .root = undefined,
            .name_pool = .empty,
        };
        errdefer self.deinit();
        const arena = self.arena.allocator();

        var iter: UnpackIterator = .init(reader);
        defer iter.deinit(allocator);

        var current = try self.pool.create(arena);
        current.* = .{
            .data = undefined,
            .entry = null,
        };

        self.root = current;

        const State = enum {
            start,
            executable_file,
            file,
            directory,
            symlink,
            next,
            first_entry,
            end,
        };

        var current_entry: UnpackIterator.Entry = undefined;

        current_entry.kind = try peekType(reader);

        state: switch (State.start) {
            .start => switch (current_entry.kind) {
                .file, .executable_file => |tag| {
                    if (options.store_file_contents) {
                        var aw: std.Io.Writer.Allocating = .init(arena);
                        _ = try iter.first(null, &aw.writer);
                        const contents = aw.toOwnedSlice() catch unreachable;
                        current.data = if (tag == .file)
                            .{ .file = contents }
                        else
                            .{ .executable_file = contents };
                    } else {
                        _, const len = try iter.firstDiscarding();
                        const contents = @as([*]u8, undefined)[0..len];
                        current.data = if (tag == .file)
                            .{ .file = contents }
                        else
                            .{ .executable_file = contents };
                    }
                    continue :state .end;
                },
                .symlink => {
                    const target = (try iter.first(null, null)).symlink;
                    current.data = .{ .symlink = try arena.dupe(u8, target) };
                    continue :state .end;
                },
                .directory => {
                    std.debug.assert(try iter.first(allocator, null) == .directory);
                    current.data = .{ .directory = null };
                    continue :state .first_entry;
                },
            },
            .first_entry => {
                if (try iter.next(allocator)) |child| {
                    const next = try self.pool.create(arena);
                    current.data.directory = next;
                    current_entry = child;
                    const child_name = try self.name_pool.create(arena);
                    @memcpy(child_name[0..child.name.len], child.name);
                    next.* = .{
                        .data = undefined,
                        .entry = .{
                            .prev = null,
                            .next = null,
                            .name = child_name[0..child.name.len],
                            .parent = current,
                        },
                    };
                    current = next;
                    switch (child.kind) {
                        .file => continue :state .file,
                        .executable_file => continue :state .executable_file,
                        .directory => continue :state .directory,
                        .symlink => continue :state .symlink,
                    }
                } else continue :state .next;
            },
            .directory => {
                std.debug.assert(try iter.take(current_entry, null) == .directory);
                current.data = .{ .directory = null };
                continue :state .first_entry;
            },
            inline .executable_file, .file => |tag| {
                var contents: []u8 = undefined;
                if (options.store_file_contents) {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    errdefer aw.deinit();
                    _ = try iter.take(current_entry, &aw.writer);
                    contents = aw.toOwnedSlice() catch unreachable; // using an arena
                } else {
                    const len = try iter.takeDiscarding(current_entry);
                    contents = @as([*]u8, undefined)[0..len];
                }
                current.data = if (tag == .file)
                    .{ .file = contents }
                else
                    .{ .executable_file = contents };
                continue :state .next;
            },
            .symlink => {
                const target = (try iter.take(current_entry, null)).symlink;
                current.data = .{ .symlink = try arena.dupe(u8, target) };
                continue :state .next;
            },
            .next => {
                if (try iter.next(allocator)) |next_entry| {
                    current_entry = next_entry;

                    const next = try self.pool.create(arena);
                    const next_name = try self.name_pool.create(arena);
                    @memcpy(next_name[0..next_entry.name.len], next_entry.name);

                    current.entry.?.next = next;
                    next.* = .{
                        .data = undefined,
                        .entry = .{
                            .parent = current.entry.?.parent,
                            .prev = current,
                            .next = null,
                            .name = next_name[0..next_entry.name.len],
                        },
                    };
                    current = next;
                    switch (next_entry.kind) {
                        .file => continue :state .file,
                        .executable_file => continue :state .executable_file,
                        .directory => continue :state .directory,
                        .symlink => continue :state .symlink,
                    }
                } else if (current.entry.?.parent.entry != null) {
                    current = current.entry.?.parent;
                    continue :state .next;
                } else continue :state .end;
            },
            .end => {
                std.debug.assert(iter.names.items.len == 0);
                try iter.finish(allocator);
                return self;
            },
        }
        comptime unreachable;
    }

    /// Converts the contents of a directory into a Nix archive. The directory passed must be
    /// opened with iteration capabilities.
    pub fn fromDirectory(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = .empty,
            .root = undefined,
            .name_pool = .empty,
        };
        errdefer self.deinit();
        const arena = self.arena.allocator();

        const root_node = try self.pool.create(arena);
        root_node.* = .{
            .entry = null,
            .data = .{ .directory = null },
        };
        self.root = root_node;

        const Iterator = struct {
            iterator: std.Io.Dir.Iterator, // holds the directory
            object: *Object,
        };

        var iters_buf: [256]Iterator = undefined;

        var iters: std.ArrayListUnmanaged(Iterator) = .initBuffer(&iters_buf);

        iters.appendAssumeCapacity(.{
            .iterator = root.iterate(),
            .object = root_node,
        });

        errdefer if (iters.items.len > 1) for (iters.items[1..]) |*x| x.iterator.reader.dir.close(io);

        while (iters.items.len != 0) {
            var cur = &iters.items[iters.items.len - 1];
            const entry = try cur.iterator.next(io);

            if (entry) |e| {
                const next = try self.pool.create(arena);
                next.*.entry = .{
                    .parent = cur.object,
                    .name = try arena.dupe(u8, e.name),
                };
                switch (e.kind) {
                    .directory => {
                        next.*.data = .{ .directory = null };
                        var child = try cur.iterator.reader.dir.openDir(io, e.name, .{
                            .iterate = true,
                            .follow_symlinks = false,
                        });
                        iters.appendBounded(.{
                            .iterator = child.iterate(),
                            .object = next,
                        }) catch return error.NestedTooDeep;
                    },
                    .sym_link => {
                        next.*.data = .{ .symlink = undefined };
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        const size = try cur.iterator.reader.dir.readLink(io, e.name, &buf);
                        next.data.symlink = try self.arena.allocator().dupe(u8, buf[0..size]);
                    },
                    else => {
                        var file = try cur.iterator.reader.dir.openFile(io, e.name, .{
                            .follow_symlinks = false,
                        });
                        defer file.close(io);

                        const stat = try file.stat(io);

                        var fr = file.reader(io, &.{});

                        var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
                        errdefer aw.deinit();
                        while (try fr.interface.streamRemaining(&aw.writer) != 0) {}
                        errdefer comptime unreachable;

                        next.data = if (stat.permissions.toMode() & 0o111 == 0)
                            .{ .file = aw.toOwnedSlice() catch unreachable }
                        else
                            .{ .executable_file = aw.toOwnedSlice() catch unreachable };
                    },
                }
                try cur.object.insertChild(next);
            } else {
                if (iters.items.len > 1) cur.iterator.reader.dir.close(io);
                _ = iters.pop().?;
            }
        }

        return self;
    }

    /// Creates a Nix archive containing a single file given its contents.
    pub fn fromFileContents(
        allocator: std.mem.Allocator,
        contents: []u8,
        is_executable: bool,
    ) std.mem.Allocator.Error!NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = .empty,
            .root = undefined,
            .name_pool = .empty,
        };
        errdefer self.deinit();

        self.root = try self.pool.create(self.arena.allocator());

        self.root.* = .{
            .entry = null,
            .data = if (is_executable)
                .{ .executable_file = contents }
            else
                .{ .file = contents },
        };

        return self;
    }

    /// Creates a NAR archive containing a single symlink given its target.
    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []u8,
    ) std.mem.Allocator.Error!NixArchive {
        var self: NixArchive = .{
            .arena = .init(allocator),
            .pool = .empty,
            .name_pool = .empty,
            .root = undefined,
        };
        errdefer self.deinit();

        self.root = try self.pool.create(self.arena.allocator());
        self.root.* = .{
            .entry = null,
            .data = .{ .symlink = target },
        };

        return self;
    }

    /// Serialize a NixArchive into the writer.
    pub fn toWriter(self: *NixArchive, writer: *std.Io.Writer) !void {
        var node = self.root;

        const allocator = self.arena.allocator();

        var iter: PackIterator = .init(writer);
        defer iter.deinit(allocator);

        switch (node.data) {
            .file => |c| {
                try iter.first(null, .file);
                const w = try iter.write(c.len);
                try w.writeAll(c);
                try iter.finish();
                return;
            },
            .executable_file => |c| {
                try iter.first(null, .executable_file);
                const w = try iter.write(c.len);
                try w.writeAll(c);
                try iter.finish();
                return;
            },
            .symlink => |target| {
                try iter.first(null, .symlink);
                const w = try iter.write(target.len);
                try w.writeAll(target);
                try iter.finish();
                return;
            },
            .directory => try iter.first(allocator, .directory),
        }

        // TODO: I left off here
        loop: while (true) {
            if (node.entry != null) {
                try Token.write(writer, &.{.directory_entry});
                try Token.writeStr(writer, node.entry.?.name);
                try Token.write(writer, &.{.directory_entry_inner});
            }

            switch (node.data) {
                .directory => |child| {
                    try Token.write(writer, &.{.directory});
                    if (child) |next| {
                        node = next;
                        continue;
                    }
                },
                .file => |data| {
                    try Token.write(writer, &.{.file});
                    if (data.is_executable) try Token.write(writer, &.{.executable_file});
                    try Token.write(writer, &.{.file_contents});
                    try Token.writeStr(writer, data.contents);
                },
                .symlink => |link| {
                    try Token.write(writer, &.{.symlink});
                    try Token.writeStr(writer, link);
                },
            }
            if (node.entry != null) try Token.write(writer, &.{.directory_entry_end});
            while ((node.entry orelse break :loop).next == null) {
                node = node.entry.?.parent;
                if (node.entry != null) try Token.write(writer, &.{.directory_entry_end});
            } else node = node.entry.?.next.?;
        }
        try Token.write(writer, &.{.archive_end});
    }

    /// Unpacks a Nix archive into a directory.
    pub fn toDirectory(self: NixArchive, io: std.Io, target_dir: std.Io.Dir) !void {
        if (self.root.data.directory == null) return;

        var item_buf: [256]std.Io.Dir = undefined;
        var items: std.ArrayList(std.Io.Dir) = .initBuffer(&item_buf);
        defer if (items.items.len > 1) for (items.items[1..]) |*dir| dir.close(io);
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
                    try cwd.writeFile(io, .{
                        .sub_path = current_node.entry.?.name,
                        .data = metadata.contents,
                        .flags = .{ .permissions = .fromMode(if (metadata.is_executable) 0o777 else 0o666) },
                    });
                },
                .symlink => |target| {
                    cwd.deleteFile(io, current_node.entry.?.name) catch {};
                    try cwd.symLink(io, target, current_node.entry.?.name, .{});
                },
                .directory => |child| {
                    if (std.mem.eql(u8, current_node.entry.?.name, "..") or
                        std.mem.containsAtLeastScalar(u8, current_node.entry.?.name, 1, '/'))
                        return error.MaliciousArchive;
                    if (std.mem.eql(u8, ".", current_node.entry.?.name))
                        return error.MaliciousArchive;
                    if (std.mem.indexOfScalar(u8, current_node.entry.?.name, 0) != null)
                        return error.MaliciousArchive;
                    try cwd.createDir(io, current_node.entry.?.name, .default_dir);
                    if (child) |node| {
                        const next = items.addOneBounded() catch return error.NestedTooDeep;
                        errdefer _ = items.pop().?;

                        next.* = try cwd.openDir(io, current_node.entry.?.name, .{});
                        current_node = node;
                        continue;
                    }
                },
            }
            while ((current_node.entry orelse return).next == null) {
                current_node = current_node.entry.?.parent;
                var dir = items.pop().?;
                if (current_node.entry != null) dir.close(io);
            }
            current_node = current_node.entry.?.next.?;
        }
    }

    /// Takes a directory and serializes it as a Nix Archive into `writer`. This is faster and more
    /// memory-efficient than calling `fromDirectory` followed by `pack`.
    pub fn packDirectory(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        writer: *std.Io.Writer,
    ) !void {
        // Idea: Make a list of nodes sorted by least depth to most depth, followed by names sorted
        // in reverse. Reading the next node is as easy as popping. `dir_indicies` is to keep track
        // of where the contents of each directory end.

        var node_names: std.heap.MemoryPoolAligned([std.fs.max_name_bytes]u8, .@"64") = .empty;
        defer node_names.deinit(allocator);

        var nodes: std.MultiArrayList(struct {
            kind: std.meta.Tag(Object.Data),
            name: []u8,
        }) = .empty;
        defer nodes.deinit(allocator);

        try nodes.ensureUnusedCapacity(allocator, 4096);

        var dirs: std.ArrayList(std.Io.Dir.Iterator) = try .initCapacity(allocator, 1);
        defer dirs.deinit(allocator);
        errdefer for (dirs.items[1..]) |*d| d.reader.dir.close(io);

        try dirs.ensureUnusedCapacity(allocator, 16);

        var dir_indicies: std.ArrayList(usize) = .empty;
        defer dir_indicies.deinit(allocator);

        try dir_indicies.ensureUnusedCapacity(allocator, 16);

        dirs.appendAssumeCapacity(dir.iterate());

        const Scan = enum { scan_directory, print };

        try Token.write(writer, &.{ .magic, .directory });

        loop: switch (Scan.scan_directory) {
            .scan_directory => {
                try dir_indicies.append(allocator, nodes.len);
                const last_iter = &dirs.items[dirs.items.len - 1];
                while (try last_iter.next(io)) |entry| {
                    try nodes.append(allocator, .{
                        .name = blk: {
                            var name = try node_names.create(allocator);
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
                nodes.sortSpan(dir_indicies.getLast(), nodes.len, struct {
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

                    try Token.write(writer, &.{.directory_entry});
                    try Token.writeStr(writer, name);
                    try Token.write(writer, &.{.directory_entry_inner});
                    switch (cur.kind) {
                        .directory => {
                            try Token.write(writer, &.{.directory});
                            try dirs.ensureUnusedCapacity(allocator, 1);
                            const d = try dirs.getLast().reader.dir.openDir(io, name, .{ .iterate = true });
                            dirs.appendAssumeCapacity(d.iterateAssumeFirstIteration());
                            continue :loop .scan_directory;
                        },
                        .file => {
                            try Token.write(writer, &.{.file});
                            var file = try dirs.getLast().reader.dir.openFile(io, name, .{});
                            defer file.close(io);
                            if ((try file.stat(io)).permissions.toMode() & 0o111 != 0)
                                try Token.write(writer, &.{.executable_file});
                            try Token.write(writer, &.{.file_contents});

                            var fr = file.reader(io, &.{});

                            if (fr.getSize()) |size| {
                                try writer.writeInt(u64, size, .little);
                                try fr.interface.streamExact64(writer, size);
                                try Token.writePadding(writer, size);
                            } else |_| {
                                @branchHint(.unlikely);
                                var aw: std.Io.Writer.Allocating = .init(allocator);
                                defer aw.deinit();

                                try aw.ensureUnusedCapacity(fr.interface.buffer.len);

                                while (try aw.writer.sendFileAll(&fr, .unlimited) != 0) {}
                                const size = aw.writer.buffered().len;
                                try writer.writeInt(u64, size, .little);
                                try writer.writeAll(aw.writer.buffered());
                                try Token.writePadding(writer, size);
                            }
                        },
                        .symlink => {
                            try Token.write(writer, &.{.symlink});
                            var buf: [std.fs.max_path_bytes]u8 = undefined;
                            const size = dirs.getLast().reader.dir.readLink(io, name, &buf) catch |e|
                                switch (e) {
                                    error.NameTooLong => unreachable,
                                    else => return e,
                                };
                            try Token.writeStr(writer, buf[0..size]);
                        },
                    }

                    try Token.write(writer, &.{.directory_entry_end});
                } else {
                    if (dirs.items.len == 1) break :loop;
                    try Token.write(writer, &.{.directory_entry_end});
                    _ = dir_indicies.pop().?;
                    var d = dirs.pop().?;
                    d.reader.dir.close(io);
                    continue :loop .print;
                }
            },
        }

        try Token.write(writer, &.{.archive_end});
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
        try Token.write(writer, &.{ .magic, .file });
        if (executable) try Token.write(writer, &.{.executable_file});
        try Token.write(writer, &.{.file_contents});

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
        try Token.writePadding(writer, sz);

        try Token.write(writer, &.{.archive_end});
    }

    pub fn packSymlink(target: []const u8, writer: *std.Io.Writer) !void {
        try Token.write(writer, &.{ .magic, .symlink });
        try Token.writeStr(writer, target);
        try Token.write(writer, &.{.archive_end});
    }

    /// Asserts the reader's buffer holds at `NixArchive.min_buffer_size` bytes.
    pub fn unpackDirectory(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: *std.Io.Reader,
        out_dir: std.Io.Dir,
        file_out_buffer: []u8,
    ) !void {
        var currents: std.ArrayList(std.Io.Dir) = .empty;
        defer currents.deinit(allocator);

        defer if (currents.items.len > 1) for (currents.items[1..]) |*d| d.close(io);

        try currents.append(allocator, out_dir);

        const State = enum { next, directory, file, symlink, end, leave_directory };

        var iter: UnpackIterator = .init(reader);
        defer iter.deinit(allocator);

        std.debug.assert(try iter.first(allocator, null) == .directory);

        var entry: UnpackIterator.Entry = undefined;

        state: switch (State.next) {
            .next => {
                entry = try iter.next(allocator) orelse continue :state .leave_directory;
                switch (entry.kind) {
                    .file => continue :state .file,
                    .directory => continue :state .directory,
                    .symlink => continue :state .symlink,
                }
            },
            .file => {
                const cur = &currents.items[currents.items.len - 1];
                const is_executable = try Token.peek(iter.reader, .executable_file);

                var file = try cur.createFile(io, entry.name, .{
                    .permissions = .fromMode(if (is_executable) 0o777 else 0o666),
                });
                defer file.close(io);

                var fw = file.writer(io, file_out_buffer);
                std.debug.assert((try iter.take(entry, &fw.interface)).file == is_executable);

                try fw.interface.flush();

                continue :state .next;
            },
            .symlink => {
                const target = (try iter.take(entry, null)).symlink;

                const cur = &currents.items[currents.items.len - 1];

                cur.symLink(io, target, entry.name, .{}) catch |e| switch (e) {
                    error.PathAlreadyExists => {
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (cur.readLink(io, entry.name, &buf)) |_| {
                            try cur.deleteTree(io, entry.name);
                            try cur.symLink(io, target, entry.name, .{});
                        } else |e2| return e2;
                    },
                    else => return e,
                };

                continue :state .next;
            },
            .directory => {
                std.debug.assert(try iter.take(entry, null) == .directory);
                const cur = &currents.items[currents.items.len - 1];

                try currents.ensureUnusedCapacity(allocator, 1);

                cur.createDir(io, entry.name, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
                const child = try cur.openDir(io, entry.name, .{});
                currents.appendAssumeCapacity(child);
                continue :state .next;
            },
            .leave_directory => {
                if (currents.items.len == 1)
                    continue :state .end
                else {
                    var cur = currents.pop().?;
                    cur.close(io);
                    entry = undefined;
                    continue :state .next;
                }
            },
            .end => {
                std.debug.assert(iter.names.items.len == 0);
                try iter.finish(allocator);
                return;
            },
        }
        comptime unreachable;
    }

    /// Reads a Nix archive containing a single file from the reader and writes it to the writer.
    /// Returns whether the file is executable. This is faster and more memory-efficient than calling
    /// `fromReader` followed by `pack`.
    /// Asserts the reader's buffer holds at `NixArchive.min_buffer_size` bytes.
    pub fn unpackFile(reader: *std.Io.Reader, writer: *std.Io.Writer) !bool {
        var iter: UnpackIterator = .init(reader);
        //iter.deinit();
        const is_executable = (try iter.first(null, writer, 0)).file;
        try iter.finish(null);
        return is_executable;
    }

    /// Reads a Nix archive containing a single symlink and returns the target. This is faster and
    /// more memory-efficient than calling `fromReader`.
    /// Asserts the reader's buffer holds at `NixArchive.min_buffer_size` bytes.
    pub fn unpackSymlink(reader: *std.Io.Reader, buffer: *[std.fs.max_path_bytes]u8) ![]u8 {
        var iter: UnpackIterator = .init(reader);
        //iter.deinit();
        const target = (try iter.first(null, null, 0)).symlink;
        @memcpy(buffer[0..target.len], target);
        try iter.finish(null);
        return buffer[0..target.len];
    }

    pub fn deinit(self: *NixArchive) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The array list must reserve at least `1 + std.mem.count(u8, path, "/")` items
pub fn normalizePath(out: *std.ArrayList([]const u8), path: []const u8) void {
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

/// The low-level tokens used to build Nix archives. As an implementation detail, some tokens are
/// combined. For deserializing Nix archives, use `NixArchive.UnpackIterator` instead.
pub const Token = enum {
    magic,
    archive_end,
    directory,
    file,
    symlink,
    executable_file,
    directory_entry,
    directory_entry_inner,
    directory_entry_end,

    pub const map = std.StaticStringMap(Token).initComptime(.{
        .{ str("nix-archive-1"), .magic },
        .{ str(")"), .archive_end },
        .{ str("(") ++ str("type") ++ str("directory"), .directory },
        .{ str("(") ++ str("type") ++ str("regular") ++ str("contents"), .file },
        .{ str("(") ++ str("type") ++ str("symlink") ++ str("target"), .symlink },
        .{ str("(") ++ str("type") ++ str("regular") ++ str("executable") ++ str("") ++
            str("contents"), .executable_file },
        .{ str("entry") ++ str("(") ++ str("name"), .directory_entry },
        .{ str(")") ++ str(")"), .directory_entry_end },
        .{ str("node"), .directory_entry_inner },
    });

    /// Returns whether the token was matched, absorbing it.
    pub fn take(reader: *std.Io.Reader, comptime token: Token) error{ReadFailed}!bool {
        return if (expect(reader, token)) |_| true else |e| switch (e) {
            error.ReadFailed => error.ReadFailed,
            error.InvalidToken => false,
        };
    }

    /// Returns whether the token was matched without absorbing it.
    pub fn peek(reader: *std.Io.Reader, comptime token: Token) !bool {
        const taken = reader.peek(toString(token).len) catch |e| switch (e) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };

        return std.mem.eql(u8, toString(token), taken);
    }

    /// Absorb the token and fail if not found.
    pub fn expect(reader: *std.Io.Reader, comptime token: Token) !void {
        return if (peek(reader, token)) |r| switch (r) {
            true => {
                reader.toss(toString(token).len);
                //std.debug.print("Got token {t}\n", .{token});
            },
            false => error.InvalidToken,
        } else |e| switch (e) {
            error.ReadFailed => error.ReadFailed,
        };
    }

    pub fn write(writer: *std.Io.Writer, comptime tokens: []const Token) !void {
        comptime var concatenated: []const u8 = "";

        comptime {
            for (tokens) |token| concatenated = concatenated ++ toString(token);
        }

        try writer.writeAll(concatenated);
    }

    inline fn toString(comptime value: Token) []const u8 {
        comptime {
            const values = Token.map.values();
            const index = std.mem.indexOfScalar(Token, values, value).?;

            return Token.map.keys()[index];
        }
    }

    pub fn takeName(reader: *std.Io.Reader) ![]u8 {
        const len = std.math.cast(Name, try reader.takeInt(u64, .little)) orelse
            return error.NameTooLarge;
        if (len == 0) return error.NameTooSmall;
        if (len > std.fs.max_name_bytes) return error.NameTooLarge;

        const read = try reader.take(std.mem.alignForward(Name, len, 8));

        if (!std.mem.allEqual(u8, read[len..], 0)) return error.InvalidPadding;

        return read[0..len];
    }

    pub fn takeTarget(reader: *std.Io.Reader) ![]u8 {
        const len = std.math.cast(Target, try reader.takeInt(u64, .little)) orelse
            return error.TargetTooLarge;

        if (len == 0) return error.TargetTooSmall;
        if (len > std.fs.max_path_bytes) return error.TargetTooLarge;

        const read = try reader.take(std.mem.alignForward(Target, len, 8));

        if (!std.mem.allEqual(u8, read[len..], 0)) return error.InvalidPadding;

        return read[0..len];
    }

    /// Converts a string to the format used in Nix archives.
    pub fn str(comptime string: []const u8) []const u8 {
        comptime {
            var buffer: [8]u8 = undefined;
            std.mem.writeInt(u64, &buffer, string.len, .little);

            const zeroes: [7]u8 = .{0} ** 7;
            return buffer ++ string ++ (if (string.len % 8 == 0) [0]u8{} else zeroes[0..padding(string.len)]);
        }
    }

    fn writeStr(writer: *std.Io.Writer, string: []const u8) !void {
        try writer.writeInt(u64, string.len, .little);
        try writer.writeAll(string);
        try writePadding(writer, string.len);
    }

    fn writePadding(writer: *std.Io.Writer, size: u64) !void {
        try writer.splatByteAll(0, padding(size));
    }

    fn padding(size: u64) u3 {
        return @truncate(-%size);
    }
};

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}

inline fn extendedBufferReader(comptime contents: []const u8) std.Io.Reader {
    var buf: [@max(contents.len, NixArchive.min_buffer_size)]u8 = undefined;
    @memcpy(buf[0..contents.len], contents);
    var reader: std.Io.Reader = .fixed(&buf);
    reader.end = contents.len;
    return reader;
}

test "single file" {
    const allocator = std.testing.allocator;

    var reader = extendedBufferReader(@embedFile("tests/README.nar"));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    try std.testing.expectEqual(reader.takeByte(), error.EndOfStream);

    try std.testing.expectEqualStrings(@embedFile("tests/README.out"), data.root.data.file.contents);
}

test "directory containing a single file" {
    const allocator = std.testing.allocator;

    var reader = extendedBufferReader(@embedFile("tests/hello.nar"));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    const dir = data.root;
    const file = dir.data.directory.?;
    try std.testing.expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.file.contents);
    try std.testing.expectEqualStrings("main.zig", file.entry.?.name);
}

test "a file, a directory, and some more files" {
    const allocator = std.testing.allocator;

    var reader = extendedBufferReader(@embedFile("tests/dir-and-files.nar"));

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

    var reader = extendedBufferReader(@embedFile("tests/symlink.nar"));

    var data = try NixArchive.fromReader(allocator, &reader, .{});
    defer data.deinit();

    try std.testing.expectEqualStrings("README.out", data.root.data.symlink);
}

test "nar from dir-and-files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var root = try std.Io.Dir.cwd().openDir(io, tests_path ++ "/dir-and-files", .{ .iterate = true });
    defer root.close(io);

    var data = try NixArchive.fromDirectory(allocator, io, root);
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
    const io = std.testing.io;

    std.Io.Dir.cwd().createDir(io, tests_path ++ "/empty", .default_dir) catch {};

    var root = try std.Io.Dir.cwd().openDir(io, tests_path ++ "/empty", .{ .iterate = true });
    defer root.close(io);

    var data = try NixArchive.fromDirectory(allocator, io, root);
    defer data.deinit();

    try std.testing.expectEqual(null, data.root.data.directory);
}

test "nar to directory to nar" {
    const allocator = std.testing.allocator;

    var reader = extendedBufferReader(@embedFile("tests/dir-and-files.nar"));

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
    const io = std.testing.io;

    std.Io.Dir.cwd().createDir(io, tests_path ++ "/complex/empty", .default_dir) catch {};

    var root = try std.Io.Dir.cwd().openDir(io, tests_path ++ "/complex", .{ .iterate = true });
    defer root.close(io);

    const expected = @embedFile("tests/complex.nar") ** 3 ++
        @embedFile("tests/complex_empty.nar") ** 2;

    var array_buf: [2 * expected.len]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&array_buf);
    const writer = &fixed;

    {
        try NixArchive.packDirectory(allocator, io, root, writer);

        var archive = try NixArchive.fromDirectory(allocator, io, root);
        defer archive.deinit();

        try archive.toWriter(writer);

        var reader = extendedBufferReader(@embedFile("tests/complex.nar"));

        var other_archive = try NixArchive.fromReader(allocator, &reader, .{});
        defer other_archive.deinit();

        try other_archive.toWriter(writer);
    }
    {
        var empty = try root.openDir(io, "empty", .{ .iterate = true });
        defer empty.close(io);

        try NixArchive.packDirectory(allocator, io, empty, writer);

        var archive = try NixArchive.fromDirectory(allocator, io, empty);
        defer archive.deinit();

        try archive.toWriter(writer);
    }

    // TODO: Add more packs and froms
    try std.testing.expectEqualSlices(u8, expected, writer.buffered());
}
