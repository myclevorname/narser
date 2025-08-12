const std = @import("std");
const tests_path = @import("tests").tests_path;

pub const max_name_len = std.fs.max_path_bytes;

pub const NixArchive = struct {
    /// The first entry is the root.
    nodes: IndexedPool(Node.Inner) = .empty,
    /// Optimization: Most file names are at most 64 bytes, which is the size of a SHA256 digest in
    /// hexadecimal.
    small_names: IndexedPool([64]u8) = .empty,
    large_names: IndexedPool([max_name_len]u8) = .empty,

    allocator: std.mem.Allocator,

    file_contents_arena: std.heap.ArenaAllocator,

    pub const FromReaderOptions = struct {
        discard_file_contents: bool = false,
    };

    pub fn fromReader(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        opts: FromReaderOptions,
    ) !NixArchive {
        std.debug.assert(reader.buffer.len >= max_name_len);

        var self: NixArchive = .{
            .allocator = allocator,
            .file_contents_arena = .init(allocator),
        };
        errdefer self.deinit();

        const root = Node.fromIndex(try self.nodes.create(allocator));
        std.debug.assert(root == .root);
        root.inner(self).* = .{
            .parent = .root,
            .next = .null,
            .prev = .null,
            .name = .none,
            .kind = .regular_file, // Must be something other than symlink
            .data = undefined,
        };

        var current = root;

        state: switch (State.archive_start) {
            .archive_start => {
                if (try Token.take(.magic, reader))
                    continue :state .object_type
                else
                    return error.NotANixArchive;
            },
            .object_type => {
                if (try Token.peek(.directory, reader))
                    continue :state .directory
                else if (try Token.peek(.file, reader))
                    continue :state .file
                else if (try Token.peek(.symlink, reader))
                    continue :state .symlink
                else
                    return error.UnexpectedToken;
            },
            .directory_entry => {
                std.debug.assert(current != .root);
                if (try Token.take(.directory_entry, reader)) {
                    const prev = current;
                    current = .fromIndex(try self.nodes.create(allocator));
                    prev.inner(self).next = Node.Optional.fromNode(current) catch unreachable;
                    current.inner(self).* = .{
                        .parent = prev.inner(self).parent,
                        .prev = Node.Optional.fromNode(prev) catch unreachable,
                        .next = .null,
                        .name = .none,
                        .kind = .regular_file, // Must be something other than symlink
                        .data = undefined,
                    };
                    continue :state .entry_name;
                } else continue :state .leave_directory;
            },
            .entry_name => {
                const size = try reader.takeInt(u64, .little);
                switch (size) {
                    0 => return error.NameTooSmall,
                    1...max_name_len => {},
                    else => return error.NameTooLarge,
                }
                try current.setName(&self, try reader.take(size));
                if (current.prev(self)) |p|
                    switch (std.mem.order(u8, p.name(self).?, current.name(self).?)) {
                        .lt => {},
                        .eq => return error.DuplicateName,
                        .gt => return error.WrongNameOrder,
                    };
                if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
                    return error.NonZeroPadding;
                continue :state .entry_node;
            },
            .entry_node => {
                try Token.expectTake(.directory_entry_inner, reader);
                continue :state .object_type;
            },
            .leave_directory => {
                try Token.expectTake(.directory_entry_end, reader);
                current = current.parent(self).?;
                continue :state if (current == .root) .archive_end else .directory_entry;
            },
            .archive_end => {
                try Token.expectTake(.archive_end, reader);
                return self;
            },
            .symlink => {
                reader.toss(Token.string(.symlink).len);
                continue :state .symlink_target;
            },
            .symlink_target => {
                const size = try reader.takeInt(u64, .little);
                switch (size) {
                    0 => return error.TargetTooSmall,
                    1...max_name_len => {},
                    else => return error.TargetTooLarge,
                }
                try current.setContents(&self, .{ .symlink = try reader.take(size) });
                if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
                    return error.NonZeroPadding;
                try Token.expectTake(.directory_entry_end, reader);
                continue :state if (current == .root) .archive_end else .directory_entry;
            },
            .file => {
                reader.toss(Token.string(.file).len);
                continue :state .executable;
            },
            .executable => {
                try current.setContents(&self, .{ .file = .{
                    .executable = try Token.take(.executable, reader),
                    .contents = &.{},
                } });
                continue :state .contents;
            },
            .contents => {
                try Token.expectTake(.file_contents, reader);
                continue :state .read_file;
            },
            .read_file => {
                const size = try reader.takeInt(u64, .little);

                // let tools like `ls` know the file size
                current.inner(self).data.file.len = size;

                if (opts.discard_file_contents) try reader.discardAll64(size) else {
                    var aw: std.Io.Writer.Allocating = try .initCapacity(
                        self.file_contents_arena.allocator(),
                        size,
                    );
                    try reader.streamExact64(&aw.writer, size);
                    current.inner(self).data.file = aw.toOwnedSlice() catch unreachable;
                }
                if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
                    return error.NonZeroPadding;
                try Token.expectTake(.directory_entry_end, reader);
                continue :state if (current == .root) .archive_end else .directory_entry;
            },
            .directory => {
                reader.toss(Token.string(.directory).len);
                try current.setContents(&self, .{ .directory = null });
                if (try Token.take(.directory_entry, reader)) {
                    const parent = current;
                    current = .fromIndex(try self.nodes.create(allocator));
                    current.inner(self).* = .{
                        .parent = parent,
                        .prev = .null,
                        .next = .null,
                        .name = .none,
                        .kind = .regular_file, // Must be something other than symlink
                        .data = undefined,
                    };
                    continue :state .entry_name;
                }
                if (current != .root) try Token.expectTake(.directory_entry_end, reader);
                continue :state if (current == .root) .archive_end else .directory_entry;
            },
        }
        comptime unreachable;
    }

    pub fn fromDirectory(allocator: std.mem.Allocator, root: std.fs.Dir) !NixArchive {
        _ = .{ allocator, root };
        unreachable; // TODO
    }

    /// Creates a NixArchive from a file given its contents.
    pub fn fromFile(
        allocator: std.mem.Allocator,
        contents: []u8,
        is_executable: bool,
    ) !NixArchive {
        var self: NixArchive = .{
            .allocator = allocator,
            .file_contents_arena = .init(allocator),
        };
        errdefer self.deinit();

        const root = Node.fromIndex(try self.nodes.create(allocator));
        std.debug.assert(root == .root);

        root.inner(self).* = .{
            .parent = .root,
            .prev = .null,
            .next = .null,
            .name = .none,
            .kind = if (is_executable) .executable_file else .regular_file,
            .data = .{ .file = contents },
        };

        return self;
    }

    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []const u8,
    ) !NixArchive {
        _ = .{ allocator, target };
        var self: NixArchive = .{
            .allocator = allocator,
            .file_contents_arena = .init(allocator),
        };
        errdefer self.deinit();

        const root = Node.fromIndex(try self.nodes.create(allocator));
        std.debug.assert(root == .root);

        root.inner(self).* = .{
            .parent = .root,
            .prev = .null,
            .next = .null,
            .name = .none,
            .kind = .symlink,
            .data = .{ .symlink = blk: {
                var t: Node.Name = .none;
                try t.set(&self, target);
                break :blk t;
            } },
        };

        return self;
    }

    pub fn dump(self: NixArchive, buffer: []u8) Reader {
        std.debug.assert(buffer.len >= 8 + max_name_len);
        return .{
            .archive = self,
            .reader = .{
                .vtable = &.{
                    .stream = &Reader.stream,
                    .discard = &Reader.discard,
                    .readVec = &Reader.readVec,
                    .rebase = &Reader.rebase,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn dumpFileDirect(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        executable: bool,
        size: ?u64,
        writer: *std.Io.Writer,
    ) !void {
        _ = .{ allocator, reader, executable, size, writer };
        unreachable; // TODO
    }

    pub fn dumpSymlinkDirect(
        target: []const u8,
        writer: *std.Io.Writer,
    ) !void {
        _ = .{ target, writer };
        unreachable; // TODO
    }

    pub fn dumpDirectoryDirect(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        writer: *std.Io.Writer,
    ) !void {
        // Idea: Make a list of nodes sorted by least depth to most depth, followed by names sorted
        // in reverse. Reading the next node is as easy as popping. `dir_indicies` is to keep track
        // of where the contents of each directory end.

        var node_names: std.heap.MemoryPool([max_name_len]u8) = .init(allocator);
        defer node_names.deinit();

        var nodes: std.MultiArrayList(struct {
            kind: enum { directory, file, symlink },
            name: []u8,
        }) = .empty;
        defer nodes.deinit(allocator);

        var dirs: std.ArrayList(std.fs.Dir.Iterator) = try .initCapacity(allocator, 1);
        defer dirs.deinit(allocator);
        errdefer for (dirs.items[1..]) |*d| d.dir.close();

        var dir_indicies: std.ArrayList(usize) = .empty;
        defer dir_indicies.deinit(allocator);

        dirs.appendAssumeCapacity(dir.iterate());

        const Scan = enum { scan_directory, print };

        try Token.write(.magic, writer);
        try Token.write(.directory, writer);

        loop: switch (Scan.scan_directory) {
            .scan_directory => {
                try dir_indicies.append(allocator, nodes.len);
                var last_iter = &dirs.items[dirs.items.len - 1];
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
                    defer node_names.destroy(@alignCast(@ptrCast(name)));

                    try Token.write(.directory_entry, writer);
                    try writeStr(writer, name);
                    try Token.write(.directory_entry_inner, writer);
                    switch (cur.kind) {
                        .directory => {
                            try Token.write(.directory, writer);
                            try dirs.ensureUnusedCapacity(allocator, 1);
                            const d = try dirs.getLast().dir.openDir(name, .{ .iterate = true });
                            dirs.appendAssumeCapacity(d.iterateAssumeFirstIteration());
                            continue :loop .scan_directory;
                        },
                        .file => {
                            try Token.write(.file, writer);
                            var file = try dirs.getLast().dir.openFile(name, .{});
                            defer file.close();
                            if (try file.mode() & 0o111 != 0) try Token.write(.executable, writer);
                            try Token.write(.file_contents, writer);

                            var buf: [4096]u8 = undefined;
                            var fw = file.reader(&buf);

                            if (fw.getSize()) |size| {
                                try writer.writeInt(u64, size, .little);
                                var left = size;
                                while (left != 0) {
                                    const read = try writer.sendFileAll(&fw, .limited64(size));
                                    left -= read;
                                    if (read == 0 and left != 0) return error.EndOfStream;
                                }
                                try writePadding(writer, size);
                            } else |_| {
                                @branchHint(.unlikely);
                                var aw: std.Io.Writer.Allocating = .init(allocator);
                                defer aw.deinit();

                                while (try aw.writer.sendFileAll(&fw, .unlimited) != 0) {}
                                const size = aw.writer.buffered().len;
                                try writer.writeInt(u64, size, .little);
                                try writer.writeAll(aw.writer.buffered());
                                try writePadding(writer, size);
                            }
                        },
                        .symlink => {
                            try Token.write(.symlink, writer);
                            var buf: [std.fs.max_path_bytes]u8 = undefined;
                            const link = dirs.getLast().dir.readLink(name, &buf) catch |e|
                                switch (e) {
                                    error.NameTooLong => unreachable,
                                    else => return e,
                                };
                            try writeStr(writer, link);
                        },
                    }

                    try Token.write(.directory_entry_end, writer);
                } else {
                    if (dirs.items.len == 1) break :loop;
                    try Token.write(.directory_entry_end, writer);
                    _ = dir_indicies.pop().?;
                    var d = dirs.pop().?;
                    d.dir.close();
                    continue :loop .print;
                }
            },
        }

        try Token.write(.archive_end, writer);
    }

    pub fn unpack(self: NixArchive, parent: std.fs.Dir, name: []const u8) !void {
        var current_node: Node = .root;

        switch (current_node.inner(self).kind) {
            .directory => {
                var root = try parent.openDir(name, .{});
                defer root.close();

                var dir_buf: [256]std.fs.Dir = undefined;
                var dirs: std.ArrayList(std.fs.Dir) = .initBuffer(&dir_buf);
                defer if (dirs.items.len >= 1) for (dirs.items[1..]) |*d| d.close();

                dirs.appendAssumeCapacity(root);

                while (true) {
                    switch (current_node.inner(self).kind) {
                        .regular_file => try dirs.getLast().writeFile(.{
                            .sub_path = current_node.name(self).?,
                            .data = current_node.inner(self).data.file,
                            .flags = .{ .mode = std.fs.File.default_mode },
                        }),
                        .executable_file => try dirs.getLast().writeFile(.{
                            .sub_path = current_node.name(self).?,
                            .data = current_node.inner(self).data.file,
                            .flags = .{ .mode = 0o777 },
                        }),
                        else => unreachable, // TODO
                    }
                }
            },
            else => unreachable, // TODO
        }
    }

    /// Unpacks an archive of a file into a writer
    pub fn unpackFileWriter(self: NixArchive, writer: *std.Io.Writer) !void {
        try writer.writeAll(Node.contents(.root, self).file.contents);
    }

    /// Unpacks a Nix archive regardless of the type of its contents.
    pub fn unpackDirect(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        root: std.fs.Dir,
        name: []const u8,
    ) !void {
        _ = .{ allocator, reader, root, name };
        unreachable; // TODO
    }

    pub fn unpackDirectory(self: NixArchive, dir: std.fs.Dir) !void {
        _ = .{ self, dir };
        unreachable; // TODO
    }

    pub fn unpackFileWriterDirect(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        try Token.expectTake(.magic, reader);
        try Token.expectTake(.file, reader);
        _ = try Token.take(.executable, reader);
        try Token.expectTake(.file_contents, reader);

        const size = try reader.takeInt(u64, .little);
        try reader.streamExact64(writer, size);
        if (!std.mem.allEqual(u8, try reader.take(padding(size)), 0))
            return error.InvalidPadding;
        try Token.expectTake(.archive_end, reader);
    }

    pub fn deinit(self: *NixArchive) void {
        self.nodes.deinit(self.allocator);
        self.small_names.deinit(self.allocator);
        self.large_names.deinit(self.allocator);
        self.file_contents_arena.deinit();
        self.* = undefined;
    }

    const Token = enum {
        magic,
        archive_end,
        directory_entry,
        directory_entry_inner,
        directory_entry_end,
        file,
        executable,
        file_contents,
        directory,
        symlink,

        const string_map: std.StaticStringMap(Token) = .initComptime(.{
            .{ str("nix-archive-1") ++ str("("), .magic },
            .{ str(")"), .archive_end },
            .{ str("entry") ++ str("(") ++ str("name"), .directory_entry },
            .{ str("node") ++ str("("), .directory_entry_inner },
            .{ str(")") ++ str(")"), .directory_entry_end },
            .{ str("type") ++ str("regular"), .file },
            .{ str("executable") ++ str(""), .executable },
            .{ str("contents"), .file_contents },
            .{ str("type") ++ str("directory"), .directory },
            .{ str("type") ++ str("symlink") ++ str("target"), .symlink },
        });

        inline fn string(comptime token: Token) []const u8 {
            const index = std.mem.indexOfScalar(Token, string_map.values(), token).?;
            return string_map.keys()[index];
        }

        fn take(comptime token: Token, reader: *std.Io.Reader) !bool {
            const peeked = reader.peekArray(token.string().len) catch |e| switch (e) {
                error.EndOfStream => return false,
                else => return e,
            };
            if (!std.mem.eql(u8, token.string(), peeked))
                return false
            else
                reader.toss(token.string().len);
            std.debug.print("Token take {s}\n", .{@tagName(token)});
            return true;
        }

        fn peek(comptime token: Token, reader: *std.Io.Reader) !bool {
            const peeked = reader.peekArray(token.string().len) catch |e| switch (e) {
                error.EndOfStream => return false,
                else => return e,
            };
            if (!std.mem.eql(u8, token.string(), peeked))
                return false;
            std.debug.print("Token peek {s}\n", .{@tagName(token)});
            return true;
        }

        fn expectTake(comptime token: Token, reader: *std.Io.Reader) !void {
            if (!std.mem.eql(u8, token.string(), try reader.peekArray(token.string().len)))
                return error.UnexpectedToken
            else
                reader.toss(token.string().len);
            std.debug.print("Token take {s}\n", .{@tagName(token)});
        }

        fn expectPeek(comptime token: Token, reader: *std.Io.Reader) !void {
            if (!std.mem.eql(u8, token.string(), try reader.peekArray(token.string().len)))
                return error.UnexpectedToken;
            std.debug.print("Token peek {s}\n", .{@tagName(token)});
        }

        fn write(comptime token: Token, writer: *std.Io.Writer) !void {
            try writer.writeAll(token.string());
        }
    };

    /// Structured to only read (Reader.take) or write one token at a time.
    const State = enum {
        archive_start,
        object_type,
        directory_entry,
        entry_name,
        entry_node,
        leave_directory,
        archive_end,
        symlink,
        symlink_target,
        file,
        executable,
        contents,
        read_file,
        directory,
    };

    pub const Node = enum(u32) {
        root = 0,
        _,

        pub const Optional = enum(u32) {
            null = 0,
            _,

            pub fn fromNode(node: Node) error{IsRootNode}!Optional {
                return switch (node) {
                    .root => error.IsRootNode,
                    _ => @enumFromInt(@intFromEnum(node)),
                };
            }

            pub fn toNode(self: Optional) ?Node {
                return switch (self) {
                    .null => null,
                    _ => @enumFromInt(@intFromEnum(self)),
                };
            }
        };

        pub const Name = struct {
            index: u32,
            /// A len of 0 means no string, which is only valid before setting its name.
            len: u32,

            /// Invalid for a symlink target
            pub const none: Name = .{ .index = undefined, .len = 0 };

            fn get(self: Name, archive: NixArchive) ?[]const u8 {
                return switch (self.len) {
                    0 => null,
                    1...64 => archive.small_names.items[self.index][0..self.len],
                    65...max_name_len => archive.large_names.items[self.index][0..self.len],
                    else => unreachable, // Invalid name
                };
            }

            fn set(self: *Name, archive: *NixArchive, new_name: ?[]const u8) !void {
                if (new_name != null and new_name.?.len == 0) return error.NameTooShort;
                if (new_name != null and new_name.?.len > max_name_len)
                    return error.NameTooLong;

                switch (self.len) {
                    0 => {},
                    1...64 => archive.small_names.destroy(self.index),
                    65...max_name_len => archive.large_names.destroy(self.index),
                    else => unreachable, // Invalid name
                }

                if (new_name) |n| {
                    self.index = switch (n.len) {
                        0 => unreachable,
                        1...64 => try archive.small_names.create(archive.allocator),
                        65...max_name_len => try archive.large_names.create(archive.allocator),
                        else => unreachable,
                    };
                    self.len = @intCast(n.len);

                    @memcpy(@constCast(self.get(archive.*).?), n);
                } else self.* = .none;
            }
        };

        pub const Kind = enum {
            regular_file,
            executable_file,
            directory,
            symlink,

            pub const Tagged = union(enum) {
                file: struct { contents: []u8, executable: bool },
                symlink: []const u8,
                directory: ?Node,
            };
        };

        pub const Inner = struct {
            /// Set to `0` for the root node as an optimization of `subPath()`
            parent: Node,
            next: Optional,
            prev: Optional,
            /// Undefined for the root node.
            name: Name,
            kind: Kind,
            data: union {
                file: []u8,
                symlink: Name,
                directory: Optional,
            },
        };

        pub fn index(self: Node) u32 {
            return @intFromEnum(self);
        }

        pub fn fromIndex(i: u32) Node {
            return @enumFromInt(i);
        }

        /// Returns a reference to the node's contents. Try using the higher-level API instead.
        fn inner(self: Node, archive: NixArchive) *Inner {
            std.debug.assert(archive.nodes.free_list[self.index()] == .allocated); // Use-after-free or use of uninitialized value
            return &archive.nodes.items[self.index()];
        }

        pub fn setName(self: Node, archive: *NixArchive, new_name: ?[]const u8) !void {
            try self.inner(archive.*).name.set(archive, new_name);
        }

        pub fn name(self: Node, archive: NixArchive) ?[]const u8 {
            return self.inner(archive).name.get(archive);
        }

        pub fn prev(self: Node, archive: NixArchive) ?Node {
            return self.inner(archive).prev.toNode();
        }

        pub fn next(self: Node, archive: NixArchive) ?Node {
            return self.inner(archive).next.toNode();
        }

        pub fn parent(self: Node, archive: NixArchive) ?Node {
            return if (self == .root) null else self.inner(archive).parent;
        }

        pub fn subPath(self: Node, archive: NixArchive, subpath: []const u8) !Node {
            _ = .{ self, archive, subpath };
            unreachable; // TODO
        }

        pub fn contents(self: Node, archive: NixArchive) Kind.Tagged {
            const kind = self.inner(archive).kind;
            const data = self.inner(archive).data;
            return switch (kind) {
                .regular_file => .{ .file = .{ .contents = data.file, .executable = false } },
                .executable_file => .{ .file = .{ .contents = data.file, .executable = true } },
                .symlink => .{ .symlink = data.symlink.get(archive).? },
                .directory => .{ .directory = data.directory.toNode() },
            };
        }

        pub fn setContents(self: Node, archive: *NixArchive, data: Kind.Tagged) !void {
            if (self.inner(archive.*).kind == .symlink)
                self.inner(archive.*).data.symlink.set(archive, null) catch unreachable;
            self.inner(archive.*).kind = switch (data) {
                .symlink => .symlink,
                .directory => .directory,
                .file => |md| if (md.executable) .executable_file else .regular_file,
            };
            self.inner(archive.*).data = switch (data) {
                .directory => |opt| .{
                    .directory = if (opt) |o| Node.Optional.fromNode(o) catch unreachable else .null,
                },
                .file => |md| .{ .file = md.contents },
                .symlink => .{ .symlink = .none },
            };
            if (data == .symlink)
                try self.inner(archive.*).data.symlink.set(archive, data.symlink);
        }
    };

    pub const Reader = struct {
        archive: NixArchive,
        state: State = .archive_start,
        file_seek: u64 = 0,
        current_node: Node = .root,
        reader: std.Io.Reader,

        fn stream(
            r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            _ = .{ r, w, limit };
            unreachable; // TODO
        }

        fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            _ = .{ r, limit };
            unreachable; // TODO
        }

        fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            _ = .{ r, data };
            unreachable; // TODO
        }

        fn rebase(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
            _ = .{ r, capacity };
            unreachable; // TODO
        }
    };
};

/// Basically std.heap.MemoryPool(T), but with 32-bit indexes (handles) instead
pub fn IndexedPool(T: type) type {
    return struct {
        /// true if free
        free_list: []Status,
        items: []T,

        const Self = @This();

        pub const empty: Self = .{ .free_list = &.{}, .items = &.{} };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.free_list);
            allocator.free(self.items);
            self.* = undefined;
        }

        pub fn create(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!u32 {
            if (std.mem.indexOfScalar(Status, self.free_list, .free)) |index| {
                self.free_list[index] = .allocated;
                return @intCast(index);
            } else {
                const old_size = self.items.len;
                const new_size = growCapacity(old_size, self.items.len + 1);

                // The self.free_list reallocation must come first because the old size is based on
                // self.items.len.
                self.free_list = try allocator.realloc(self.free_list, new_size);
                self.items = try allocator.realloc(self.items, new_size);

                @memset(self.free_list[old_size + 1 .. new_size], .free);
                self.free_list[old_size] = .allocated;
                return @intCast(old_size);
            }
        }

        pub fn destroy(self: Self, index: u32) void {
            std.debug.assert(self.free_list[index] == .allocated); // Double-free
            self.free_list[index] = .free;
            self.items[index] = undefined;
        }

        pub const Status = enum(u1) { free, allocated };
    };
}

// Copied from https://github.com/ziglang/zig/blob/749f10af49022597d873d41df5c600e97e5c4a37/lib/std/array_list.zig#L1410
fn growCapacity(current: usize, minimum: usize) usize {
    const init_capacity = 1;
    var new = current;
    while (true) {
        new +|= new / 2 + init_capacity;
        if (new >= minimum) return new;
    }
}

inline fn str(comptime string: []const u8) []const u8 {
    var int_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &int_buf, string.len, .little);
    return int_buf ++ string ++
        @as([padding(string.len)]u8, @splat(0));
}

fn writeStr(writer: *std.Io.Writer, string: []const u8) !void {
    try writer.writeInt(u64, string.len, .little);
    try writer.writeAll(string);
    try writePadding(writer, string.len);
}

fn writePadding(writer: *std.Io.Writer, size: u64) !void {
    return writer.splatByteAll(0, padding(size));
}

fn padding(size: u64) u3 {
    return @intCast(0b111 & -%size);
}

// TODO: tests
test {
    _ = comptime std.testing.refAllDeclsRecursive(@This());
}
