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

    pub const min_buffer_size = std.fs.max_path_bytes + Token.toString(.directory_entry_end).len;

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

    /// A higher-level directory entry-based iterator built upon `Token`.
    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
    pub const UnpackIterator = struct {
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        names: std.ArrayList(struct {
            name: [std.fs.max_name_bytes]u8,
            len: Name,
        }),

        pub const Entry = struct {
            /// Invalidated upon `.skip` or `.take`
            name: []const u8,
            kind: std.meta.Tag(Object.Data),
        };

        pub const Contents = union(std.meta.Tag(Object.Data)) {
            file: bool,
            /// Invalidated upon `.skip` or `.take`
            symlink: []const u8,
            directory,
        };

        pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) UnpackIterator {
            std.debug.assert(reader.buffer.len >= std.fs.max_path_bytes +
                Token.toString(.directory_entry_end).len);
            return .{
                .allocator = allocator,
                .reader = reader,
                .names = .empty,
            };
        }

        pub fn deinit(self: *UnpackIterator) void {
            self.names.deinit(self.allocator);
            self.* = undefined;
        }

        /// Get the contents of the root node. Depending on the type, the following will happen:
        ///
        /// `.file`: Stream the contents into the writer
        /// `.directory`: Enter the directory
        /// `.symlink`: Return the slice
        pub fn first(self: *UnpackIterator, writer: ?*std.Io.Writer, depth_hint: usize) !Contents {
            const kind = try peekType(self.reader);

            std.debug.assert((kind == .file) == (writer != null));

            Token.expect(self.reader, .magic) catch unreachable;

            switch (kind) {
                .file => {
                    Token.expect(self.reader, .file) catch unreachable;
                    const is_executable = try Token.take(self.reader, .executable_file);
                    try Token.expect(self.reader, .file_contents);

                    const len = try self.reader.takeInt(u64, .little);
                    try self.reader.streamExact64(writer.?, len);
                    if (!std.mem.allEqual(u8, try self.reader.take(Token.padding(len)), 0))
                        return error.InvalidPadding;

                    return .{ .file = is_executable };
                },
                .symlink => {
                    Token.expect(self.reader, .symlink) catch unreachable;
                    const target = try Token.takeTarget(self.reader);
                    return .{ .symlink = target };
                },
                .directory => {
                    Token.expect(self.reader, .directory) catch unreachable;
                    try self.names.ensureTotalCapacity(self.allocator, depth_hint);
                    const first_name = self.names.addOneAssumeCapacity();
                    first_name.len = 0;
                    std.debug.assert(first_name == &self.names.items[0]);
                    return .directory;
                },
            }
        }

        /// Get the next entry within the current directory. `null` means leaving a directory.
        pub fn next(self: *UnpackIterator) !?Entry {
            if (try Token.take(self.reader, .directory_entry)) {
                const prev_buf = &self.names.items[self.names.items.len - 1];
                const prev = prev_buf.name[0..prev_buf.len];

                const next_name = try Token.takeName(self.reader);

                if (std.mem.indexOfScalar(u8, next_name, 0) != null or
                    std.mem.indexOfScalar(u8, next_name, '/') != null or
                    std.mem.eql(u8, next_name, ".") or
                    std.mem.eql(u8, next_name, ".."))
                {
                    return error.MaliciousArchive;
                }

                switch (std.mem.order(u8, prev, next_name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                }
                @memcpy(prev_buf.name[0..next_name.len], next_name);
                prev_buf.len = @intCast(next_name.len);

                try Token.expect(self.reader, .directory_entry_inner);
                const kind: std.meta.Tag(Object.Data) = if (try Token.take(self.reader, .file))
                    .file
                else if (try Token.take(self.reader, .directory))
                    .directory
                else if (try Token.take(self.reader, .symlink))
                    .symlink
                else
                    return error.InvalidToken;
                return .{
                    .kind = kind,
                    .name = prev_buf.name[0..next_name.len],
                };
            } else {
                if (self.names.items.len > 1) try Token.expect(self.reader, .directory_entry_end);
                _ = self.names.pop().?;
                return null;
            }
        }

        /// Skip the current entry and its contents.
        pub fn skip(self: *UnpackIterator, entry: Entry) !void {
            std.debug.assert(self.names.items.len != 0);
            const State = enum {
                start,
                file,
                symlink,
                next,
            };

            const depth = self.names.items.len;

            state: switch (State.start) {
                .start => switch (entry.kind) {
                    .file => continue :state .file,
                    .symlink => continue :state .symlink,
                    .directory => {
                        const child = try self.names.addOne(self.allocator);
                        child.len = 0;
                        continue :state .next;
                    },
                },
                .file => {
                    _ = try Token.take(self.reader, .executable_file);
                    try Token.expect(self.reader, .file_contents);
                    const len = try self.reader.takeInt(u64, .little);
                    try self.reader.discardAll64(len);
                    const zeroes = try self.reader.take(Token.padding(len));
                    if (!std.mem.allEqual(u8, zeroes, 0))
                        return error.InvalidPadding;
                    try Token.expect(self.reader, .directory_entry_end);
                    continue :state .next;
                },
                .symlink => {
                    _ = try Token.takeTarget(self.reader);
                    try Token.expect(self.reader, .directory_entry_end);
                    continue :state .next;
                },
                .next => {
                    if (self.names.items.len == depth) return;
                    if (try self.next()) |e| {
                        switch (e.kind) {
                            .file => continue :state .file,
                            .symlink => continue :state .symlink,
                            .directory => {
                                std.debug.assert(try self.take(e, null) == .directory);
                                continue :state .next;
                            },
                        }
                    } else {
                        continue :state .next;
                    }
                },
            }
            comptime unreachable;
        }

        /// Take the current entry's contents. Depending on the entry, the following will happen:
        ///
        /// `.file`: Stream the contents into the writer
        /// `.directory`: Enter the directory
        /// `.symlink`: Return the slice
        pub fn take(self: *UnpackIterator, entry: Entry, writer: ?*std.Io.Writer) !Contents {
            std.debug.assert((entry.kind == .file) == (writer != null));
            switch (entry.kind) {
                .directory => {
                    const child = try self.names.addOne(self.allocator);
                    child.len = 0;
                    return .directory;
                },
                .file => {
                    const is_executable = try Token.take(self.reader, .executable_file);
                    try Token.expect(self.reader, .file_contents);

                    const len = try self.reader.takeInt(u64, .little);
                    try self.reader.streamExact64(writer.?, len);
                    if (!std.mem.allEqual(u8, try self.reader.take(Token.padding(len)), 0))
                        return error.InvalidPadding;

                    try Token.expect(self.reader, .directory_entry_end);

                    return .{ .file = is_executable };
                },
                .symlink => {
                    self.reader.fillMore() catch |e| switch (e) {
                        error.EndOfStream => {},
                        error.ReadFailed => return e,
                    };
                    // there must be enough space otherwise EOF will occur
                    const target = try Token.takeTarget(self.reader);
                    try Token.expect(self.reader, .directory_entry_end); // shouldn't rebase
                    return .{ .symlink = target };
                },
            }
        }

        /// Take the current directory entry's contents and discards the file contents.
        /// Asserts the current directory entry is a file.
        pub fn takeDiscarding(self: *UnpackIterator, entry: Entry) !struct { bool, u64 } {
            std.debug.assert(entry.kind == .file);
            const ret = try self.firstDiscarding();

            try Token.expect(self.reader, .directory_entry_end);
            return ret;
        }

        pub fn firstDiscarding(self: *UnpackIterator) !struct { bool, u64 } {
            const is_executable = try Token.take(self.reader, .executable_file);
            try Token.expect(self.reader, .file_contents);

            const len = try self.reader.takeInt(u64, .little);
            try self.reader.discardAll64(len);

            if (!std.mem.allEqual(u8, try self.reader.take(Token.padding(len)), 0))
                return error.InvalidPadding;

            return .{ is_executable, len };
        }

        /// Finish parsing the archive. This does not free the memory: call `.deinit` after.
        pub fn finish(self: *UnpackIterator) !void {
            while (self.names.items.len != 0) {
                if (try self.next()) |e| _ = try self.skip(e);
            }

            try Token.expect(self.reader, .archive_end);
        }
    };

    /// Returns the type of archive in the reader. Asserts the reader buffer is at least 80 bytes.
    pub fn peekType(reader: *std.Io.Reader) !std.meta.Tag(Object.Data) {
        const magic = Token.toString(.magic);
        const file = Token.toString(.file);
        const directory = Token.toString(.directory);
        const symlink = Token.toString(.symlink);

        if (magic.len + directory.len != 80) {
            @compileLog(magic.len + directory.len);
            @compileError("archiveType doc comment needs updated as well as the other instances of the magic number");
        }

        std.debug.assert(reader.buffer.len >= magic.len + directory.len);

        if (!std.mem.eql(u8, try reader.peek(magic.len), magic)) {
            std.testing.expectEqualSlices(u8, reader.peek(magic.len) catch unreachable, magic) catch {};
            return error.NotANar;
        }

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
    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
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
        const arena = self.arena.allocator();
        self.name_pool = .init(self.arena.allocator());
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        var iter: UnpackIterator = .init(allocator, reader);
        defer iter.deinit();

        var current = try self.pool.create();
        current.* = .{
            .data = undefined,
            .entry = null,
        };

        self.root = current;

        const State = enum {
            start,
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
                .file => {
                    if (options.store_file_contents) {
                        var aw: std.Io.Writer.Allocating = .init(arena);
                        const is_executable = (try iter.first(&aw.writer, 0)).file;
                        current.data = .{ .file = .{
                            .is_executable = is_executable,
                            .contents = aw.toOwnedSlice() catch unreachable,
                        } };
                    } else {
                        const is_executable, const len = try iter.firstDiscarding();
                        current.data = .{ .file = .{
                            .is_executable = is_executable,
                            .contents = @as([*]u8, undefined)[0..len],
                        } };
                    }
                    continue :state .end;
                },
                .symlink => {
                    const target = (try iter.first(null, 0)).symlink;
                    current.data = .{ .symlink = try arena.dupe(u8, target) };
                    continue :state .end;
                },
                .directory => {
                    std.debug.assert(try iter.first(null, 1) == .directory);
                    current.data = .{ .directory = null };
                    continue :state .first_entry;
                },
            },
            .first_entry => {
                if (try iter.next()) |child| {
                    const next = try self.pool.create();
                    current.data.directory = next;
                    current_entry = child;
                    const child_name = try self.name_pool.create();
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
            .file => {
                if (options.store_file_contents) {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    const is_executable = (try iter.take(current_entry, &aw.writer)).file;
                    current.data = .{ .file = .{
                        .is_executable = is_executable,
                        .contents = aw.toOwnedSlice() catch unreachable,
                    } };
                } else {
                    const is_executable, const len = try iter.takeDiscarding(current_entry);
                    current.data = .{ .file = .{
                        .is_executable = is_executable,
                        .contents = @as([*]u8, undefined)[0..len],
                    } };
                }
                continue :state .next;
            },
            .symlink => {
                const target = (try iter.take(current_entry, null)).symlink;
                current.data = .{ .symlink = try arena.dupe(u8, target) };
                continue :state .next;
            },
            .next => {
                if (try iter.next()) |next_entry| {
                    current_entry = next_entry;

                    const next = try self.pool.create();
                    const next_name = try self.name_pool.create();
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
                try iter.finish();
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

        try Token.write(writer, &.{.magic});

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

        try Token.write(writer, &.{ .magic, .directory });

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

                    try Token.write(writer, &.{.directory_entry});
                    try Token.writeStr(writer, name);
                    try Token.write(writer, &.{.directory_entry_inner});
                    switch (cur.kind) {
                        .directory => {
                            try Token.write(writer, &.{.directory});
                            try dirs.ensureUnusedCapacity(allocator, 1);
                            const d = try dirs.getLast().dir.openDir(name, .{ .iterate = true });
                            dirs.appendAssumeCapacity(d.iterateAssumeFirstIteration());
                            continue :loop .scan_directory;
                        },
                        .file => {
                            try Token.write(writer, &.{.file});
                            var file = try dirs.getLast().dir.openFile(name, .{});
                            defer file.close();
                            if (try file.mode() & 0o111 != 0)
                                try Token.write(writer, &.{.executable_file});
                            try Token.write(writer, &.{.file_contents});

                            var fr = file.reader(&.{});

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
                            const link = dirs.getLast().dir.readLink(name, &buf) catch |e|
                                switch (e) {
                                    error.NameTooLong => unreachable,
                                    else => return e,
                                };
                            try Token.writeStr(writer, link);
                        },
                    }

                    try Token.write(writer, &.{.directory_entry_end});
                } else {
                    if (dirs.items.len == 1) break :loop;
                    try Token.write(writer, &.{.directory_entry_end});
                    _ = dir_indicies.pop().?;
                    var d = dirs.pop().?;
                    d.dir.close();
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

    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
    pub fn unpackDirectory(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        out_dir: std.fs.Dir,
        file_out_buffer: []u8,
    ) !void {
        var currents: std.ArrayList(std.fs.Dir) = .empty;
        defer currents.deinit(allocator);

        defer if (currents.items.len > 1) for (currents.items[1..]) |*d| d.close();

        try currents.append(allocator, out_dir);

        const State = enum { next, directory, file, symlink, end, leave_directory };

        var iter: UnpackIterator = .init(allocator, reader);
        defer iter.deinit();

        std.debug.assert(try iter.first(null, 1) == .directory); // TODO: depth_hint as arg

        var entry: UnpackIterator.Entry = undefined;
        var entry_name_buf: [std.fs.max_name_bytes]u8 = undefined;

        state: switch (State.next) {
            .next => {
                entry = try iter.next() orelse continue :state .leave_directory;
                @memcpy(entry_name_buf[0..entry.name.len], entry.name);
                entry.name.ptr = &entry_name_buf;

                switch (entry.kind) {
                    .file => continue :state .file,
                    .directory => continue :state .directory,
                    .symlink => continue :state .symlink,
                }
            },
            .file => {
                const cur = &currents.items[currents.items.len - 1];
                const is_executable = try Token.peek(iter.reader, .executable_file);

                var file = try cur.createFile(entry.name, .{
                    .mode = if (is_executable) 0o777 else 0o666,
                });
                defer file.close();

                var fw = file.writer(file_out_buffer);
                std.debug.assert((try iter.take(entry, &fw.interface)).file == is_executable);

                try fw.interface.flush();

                continue :state .next;
            },
            .symlink => {
                const target = (try iter.take(entry, null)).symlink;

                const cur = &currents.items[currents.items.len - 1];

                cur.symLink(target, entry.name, .{}) catch |e| switch (e) {
                    error.PathAlreadyExists => {
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (cur.readLink(entry.name, &buf)) |_| {
                            try cur.deleteTree(entry.name);
                            try cur.symLink(target, entry.name, .{});
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

                cur.makeDir(entry.name) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
                const child = try cur.openDir(entry.name, .{});
                currents.appendAssumeCapacity(child);
                continue :state .next;
            },
            .leave_directory => {
                if (currents.items.len == 1)
                    continue :state .end
                else {
                    var cur = currents.pop().?;
                    cur.close();
                    entry = undefined;
                    continue :state .next;
                }
            },
            .end => {
                std.debug.assert(iter.names.items.len == 0);
                try iter.finish();
                return;
            },
        }
        comptime unreachable;
    }

    /// Reads a Nix archive containing a single file from the reader and writes it to the writer.
    /// Returns whether the file is executable. This is faster and more memory-efficient than calling
    /// `fromReader` followed by `pack`.
    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
    pub fn unpackFile(reader: *std.Io.Reader, writer: *std.Io.Writer) !bool {
        var iter: UnpackIterator = .init(undefined, reader);
        //iter.deinit();
        const is_executable = (try iter.first(writer, 0)).file;
        try iter.finish();
        return is_executable;
    }

    /// Reads a Nix archive containing a single symlink and returns the target. This is faster and
    /// more memory-efficient than calling `fromReader`.
    /// The reader's buffer must have at least `NixArchive.min_buffer_size` bytes.
    pub fn unpackSymlink(reader: *std.Io.Reader, buffer: *[std.fs.max_path_bytes]u8) ![]u8 {
        var iter: UnpackIterator = .init(undefined, reader);
        //iter.deinit();
        const target = (try iter.first(null, 0)).symlink;
        @memcpy(buffer[0..target.len], target);
        try iter.finish();
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
    file_contents,
    directory_entry,
    directory_entry_inner,
    directory_entry_end,

    pub const map = std.StaticStringMap(Token).initComptime(.{
        .{ str("nix-archive-1"), .magic },
        .{ str(")"), .archive_end },
        .{ str("(") ++ str("type") ++ str("directory"), .directory },
        .{ str("(") ++ str("type") ++ str("regular"), .file },
        .{ str("(") ++ str("type") ++ str("symlink") ++ str("target"), .symlink },
        .{ str("executable") ++ str(""), .executable_file },
        .{ str("contents"), .file_contents },
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

        var reader = extendedBufferReader(@embedFile("tests/complex.nar"));

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
