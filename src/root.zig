const std = @import("std");
const tests_path = @import("tests").tests_path;

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const mem = std.mem;
const divCeil = std.math.divCeil;

comptime {
    if (std.fs.max_path_bytes <= 64) @compileError("std.fs.max_path_bytes is too small");
}

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
pub const NarArchive = struct {
    file_contents_arena: std.heap.ArenaAllocator,
    list_allocator: std.mem.Allocator,
    /// For smaller file names (64 is the length of a SHA256 hash in hexadecimal)
    small_name_list: MemoryPoolIndex([64]u8, .@"64") = .empty,
    large_name_list: MemoryPoolIndex([std.fs.max_path_bytes]u8, .@"64") = .empty,
    node_list: MemoryPoolIndex(Object, null) = .empty,

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self: NarArchive = .{
            .file_contents_arena = .init(allocator),
            .list_allocator = allocator,
        };
        errdefer self.deinit();

        var stream = slice;

        var current = try self.node_list.create(allocator);
        var current_node = self.node(current);
        current_node.* = .{
            .parent = 0,
            .data = undefined,
            .name_index = 0,
            .name_len = 0,
        };

        const State = enum {
            start,
            get_object_type,
            get_entry,
            get_entry_inner,
            regular_file,
            executable_file,
            directory,
            symlink,
            next,
            next_skip_end,
            leave_directory,
            end,
        };
        state: switch (State.start) {
            .start => {
                expectToken(&stream, .magic) catch return error.NotANar;

                continue :state .get_object_type;
            },
            .get_object_type => {
                if (matches(&stream, .regular_file))
                    continue :state .regular_file
                else if (matches(&stream, .executable_file))
                    continue :state .executable_file
                else if (matches(&stream, .directory))
                    continue :state .directory
                else if (matches(&stream, .symlink))
                    continue :state .symlink
                else
                    return error.UnexpectedToken;
            },
            .get_entry => {
                try expectToken(&stream, .directory_entry);
                continue :state .get_entry_inner;
            },
            .get_entry_inner => {
                const name = try unstr(&stream);
                try self.allocName(current, name);
                if (current_node.prev.index()) |p|
                    switch (std.mem.order(u8, self.nameString(p), self.nameString(current))) {
                        .lt => {},
                        .eq => return error.DuplicateObjectName,
                        .gt => return error.WrongDirectoryOrder,
                    };
                try expectToken(&stream, .directory_entry_inner);
                continue :state .get_object_type;
            },
            .directory => {
                current_node.data = .{ .directory = .from(null) };
                if (current != 0) {
                    if (matches(&stream, .directory_entry_end)) continue :state .next_skip_end;
                } else {
                    if (matches(&stream, .archive_end)) {
                        if (stream.len != 0) return error.InvalidFormat else break :state;
                    }
                }

                // there must be a child at this point

                const child = try self.node_list.create(allocator);
                self.node(current).data.directory = .from(child);
                self.node(child).* = .{
                    .parent = current,
                    .name_index = undefined,
                    .name_len = undefined,
                    .data = undefined,
                };
                current = child;
                current_node = self.node(child);
                continue :state .get_entry;
            },
            .regular_file => {
                current_node.data = .{ .regular_file = try unstr(&stream) };
                continue :state .next;
            },
            .executable_file => {
                current_node.data = .{ .executable_file = try unstr(&stream) };
                continue :state .next;
            },
            .symlink => {
                current.data = .{ .symlink = try unstr(&stream) };
                continue :state .next;
            },
            .next => {
                if (current != 0) {
                    try expectToken(&stream, .directory_entry_end);
                    continue :state .leave_directory;
                } else continue :state .end;
            },
            .next_skip_end => {
                continue :state (if (current != 0) .leave_directory else .end);
            },
            .leave_directory => {
                while (current != 0 and matches(&stream, .directory_entry_end)) {
                    current = self.node(current).parent;
                } else {
                    if (current != 0 and matches(&stream, .directory_entry)) {
                        const next = try self.node_list.create(allocator);
                        self.node(current).next = .from(next);
                        self.node(next).* = .{
                            .parent = current.parent,
                            .prev = .from(current),
                            .name_index = undefined,
                            .name_len = undefined,
                            .data = undefined,
                        };
                        current = next;
                        current_node = self.node(next);
                        continue :state .get_entry_inner;
                    } else {
                        continue :state .end;
                    }
                }
            },
            .end => {
                try expectToken(&stream, .archive_end);
                if (stream.len != 0) return error.InvalidFormat;
                break :state;
            },
        }

        //std.debug.print("Success\n", .{});
        return self;
    }

    /// Converts the contents of a directory into a Nix archive. The directory passed must be
    /// opened with `.{ .iterate = true }`
    pub fn fromDirectory(allocator: std.mem.Allocator, root: std.fs.Dir) !NarArchive {
        var self: NarArchive = .{
            .file_contents_arena = .init(allocator),
            .list_allocator = allocator,
        };
        errdefer self.deinit();

        var current = try self.node_list.create(allocator);
        self.node(current).* = .{
            .parent = 0,
            .name_index = 0,
            .name_len = 0,
            .data = .{ .directory = null },
        };

        // the iterator holds the directory
        var iters: std.BoundedArray(std.fs.Dir.Iterator, 256) = .{};

        iters.appendAssumeCapacity(root.iterate());

        errdefer if (iters.len > 1) for (iters.slice()[1..]) |*x| x.dir.close();

        while (iters.len != 0) {
            var cur = &iters.slice()[iters.len - 1];
            const entry = try cur.next();

            if (entry) |e| {
                const next = try self.node_list.create();
                self.node(next).* = .{
                    .parent = current,
                    .name_index = undefined,
                    .name_len = undefined,
                };
                try self.allocName(next, entry.name);
                switch (e.kind) {
                    .directory => {
                        self.node(next).data = .{ .directory = null };
                        var child = try cur.iterator.dir.openDir(e.name, .{ .iterate = true });
                        errdefer child.close();
                        iters.append(child.iterate()) catch return error.NestedTooDeep;
                        current = next;
                    },
                    .sym_link => {
                        self.node(next).data = .{ .symlink = undefined };
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        const link = try cur.iterator.dir.readLink(e.name, &buf);
                        try allocSymlink(next, link);
                    },
                    else => {
                        const stat = try cur.iterator.dir.statFile(e.name);
                        const contents = try cur.iterator.dir.readFileAllocOptions(
                            self.file_contents_arena.allocator(),
                            e.name,
                            std.math.maxInt(usize),
                            std.math.cast(usize, stat.size) orelse std.math.maxInt(usize),
                            .of(u8),
                            null,
                        );
                        self.node(next).data = switch (stat.mode & 1) {
                            0 => .{ .regular_file = contents },
                            1 => .{ .executable_file = contents },
                        };
                    },
                }
                try current.insertChild(next);
            } else {
                current = self.node(current).parent;
                if (iters.len > 1) cur.iterator.dir.close();
                _ = iters.pop().?;
            }
        }

        return self;
    }

    /// Creates a NAR archive containing a single file given its contents.
    pub fn fromFileContents(
        allocator: std.mem.Allocator,
        contents: []u8,
        is_executable: bool,
    ) std.mem.Allocator.Error!NarArchive {
        var self: NarArchive = .{
            .file_contents_arena = .init(allocator),
            .list_allocator = allocator,
        };
        errdefer self.deinit();

        const file = try self.node_list.create(allocator);

        self.node(file).* = .{
            .parent = 0,
            .name_index = 0,
            .name_len = 0,
            .data = switch (is_executable) {
                false => .{ .regular_file = contents },
                true => .{ .executable_file = contents },
            },
        };

        return self;
    }

    /// Creates a NAR archive containing a single symlink given its target.
    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []const u8,
    ) std.mem.Allocator.Error!NarArchive {
        var self: NarArchive = .{
            .file_contents_arena = .init(allocator),
            .list_allocator = allocator,
        };

        const root = try self.node_list.create();

        self.node(root).* = .{
            .parent = 0,
            .name_index = 0,
            .name_len = 0,
            .data = .{ .symlink = undefined },
        };

        try self.allocSymlink(root, target);
    }

    /// Serialize a NarArchive into the writer.
    pub fn dump(self: *const NarArchive, writer: anytype) !void {
        var current = 0;

        try writeTokens(writer, &.{.magic});

        loop: while (true) {
            if (current != 0) {
                try writeTokens(writer, &.{.directory_entry});
                try strWriter(self.nameString(current), writer);
                try writeTokens(writer, &.{.directory_entry_inner});
            }

            switch (node.data) {
                .directory => |child| {
                    try writeTokens(writer, &.{.directory});
                    if (child.index()) |next| {
                        current = next;
                        continue;
                    }
                },
                .regular_file => |data| {
                    try writeTokens(writer, &.{.regular_file});
                    try strWriter(data, writer);
                },
                .executable_file => |data| {
                    try writeTokens(writer, &.{.executable_file});
                    try strWriter(data, writer);
                },
                .symlink => {
                    try writeTokens(writer, &.{.symlink});
                    try strWriter(self.symlinkString(current), writer);
                },
            }
            if (current != 0) try writeTokens(writer, &.{.directory_entry_end});
            while (self.node(current).next.index() == null) {
                if (current == 0) break :loop;
                current = self.node(current).parent;
                if (current != 0) try writeTokens(writer, &.{.directory_entry_end});
            } else current = self.node(current).next.index().?;
        }
        try writeTokens(writer, &.{.archive_end});
    }

    /// Unpacks a Nix archive into a directory.
    pub fn unpackDir(self: *const NarArchive, target_dir: std.fs.Dir) !void {
        if (self.root.data.directory == null) return;

        var items: std.BoundedArray(std.fs.Dir, 256) = .{};
        defer if (items.len > 1) for (items.slice()[1..]) |*dir| dir.close();
        items.appendAssumeCapacity(target_dir);

        var current_node = self.root.data.directory.?;

        const lastItem = struct {
            fn f(array: anytype) ?@TypeOf(array.buffer[0]) {
                const slice = array.slice();
                return if (slice.len == 0) null else slice[slice.len - 1];
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
                        try items.ensureUnusedCapacity(1);
                        const next = try cwd.openDir(current_node.entry.?.name, .{});
                        items.appendAssumeCapacity(next);
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

    pub fn node(self: *NarArchive, index: u32) *Object {
        return &self.node_list.array_list.items[index];
    }

    pub fn symlinkString(self: *NarArchive, node_index: u32) []u8 {
        const node = self.current(node_index);
        const index = node.data.symlink.index;
        const len = node.data.symlink.len;
        return switch (len) {
            0 => unreachable, // Don't call this on the root node!
            1...64 => self.small_name_list.array_list.items[index][0..len],
            65...std.fs.max_path_bytes => self.large_name_list.array_list.items[index][0..len],
            else => unreachable, // Not a valid string
        };
    }

    pub fn nameString(self: *NarArchive, node_index: u32) []u8 {
        const node = self.current(node_index);
        const index = node.name_index;
        const len = node.name_len;
        return switch (len) {
            0 => unreachable, // Don't call this on the root node!
            1...64 => self.small_name_list.array_list.items[index][0..len],
            65...std.fs.max_path_bytes => self.large_name_list.array_list.items[index][0..len],
            else => unreachable, // Not a valid string
        };
    }

    pub fn allocSymlink(self: *NarArchive, node_index: u32, target: []const u8) EncodeError!void {
        self.node(node_index).data.symlink.index = switch (name.len) {
            0 => return error.NameTooBig,
            1...64 => try self.small_name_list.create(),
            65...std.fs.max_path_bytes => try self.large_name_list.create(),
            else => return error.NameTooBig,
        };
        self.node(node_index).data.symlink.len = name.len;
        @memcpy(self.nameString(node_index), name);
    }

    pub fn allocName(self: *NarArchive, node_index: u32, name: []const u8) EncodeError!void {
        self.node(node_index).name_index = switch (name.len) {
            0 => return error.NameTooBig,
            1...64 => try self.small_name_list.create(),
            65...std.fs.max_path_bytes => try self.large_name_list.create(),
            else => return error.NameTooBig,
        };
        self.node(node_index).name_len = name.len;
        @memcpy(self.nameString(node_index), name);
    }

    pub fn deinit(self: *NarArchive) void {
        const a = self.list_allocator;
        self.file_contents_arena.deinit();
        self.small_name_list.deinit(a);
        self.large_name_list.deinit(a);
        self.node_list.deinit(a);
        self.* = undefined;
    }
};

pub fn MemoryPoolIndex(comptime T: type, comptime alignment: ?std.mem.Alignment) type {
    return struct {
        free_list: std.ArrayListUnmanaged(u32),
        array_list: std.ArrayListAlignedUnmanaged(T, alignment),

        pub const empty: Self = .{
            .free_list = .empty,
            .array_list = .empty,
        };

        pub fn create(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!u32 {
            if (self.free_list.pop()) |index|
                return index
            else {
                _ = try self.array_list.addOne(allocator);
                try self.free_list.ensureTotalCapacity(allocator, self.array_list.items.len);
                return @intCast(self.array_list.item.len - 1);
            }
        }

        pub fn destroy(self: *Self, index: u32) void {
            try self.free_list.appendAssumeCapacity(index);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.free_list.deinit(allocator);
            self.array_list.deinit(allocator);
            self.* = undefined;
        }

        const Self = @This();
    };
}

/// Takes a directory and serializes it as a Nix Archive into `writer`. This is faster and more
/// memory-efficient than calling `fromDirectory` followed by `dump`.
pub fn dumpDirectory(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    writer: anytype,
) !void {
    const NamedObject = struct {
        name: [std.fs.max_path_bytes]u8 = undefined,
        object: Object,
    };

    const ObjectIterator = struct {
        current: ?*Object = null,

        const Self = @This();

        fn next(self: *Self) ?*Object {
            const ret = self.current;

            if (ret) |cur| self.current = cur.entry.?.next;
            return ret;
        }
    };

    try writeTokens(writer, &.{ .magic, .directory });

    var iterators: std.BoundedArray(struct {
        dir_iter: std.fs.Dir.Iterator,
        object: *NamedObject,
        object_iter: ObjectIterator = .{},
    }, 256) = .{};
    defer if (iterators.len > 1) for (iterators.slice()[1..]) |*iter| iter.dir_iter.dir.close();

    var objects = std.heap.MemoryPool(NamedObject).init(allocator);
    defer objects.deinit();

    const root_object = try objects.create();

    root_object.object = .{
        .entry = null,
        .data = .{ .directory = null },
    };

    iterators.appendAssumeCapacity(.{
        .dir_iter = root_dir.iterate(),
        .object = root_object,
    });

    next_dir: while (true) {
        var cur = &iterators.buffer[iterators.len - 1];

        if (cur.object_iter.current == null) while (try cur.dir_iter.next()) |entry| {
            const next_object = try objects.create();

            @memcpy(next_object.name[0..entry.name.len], entry.name);
            next_object.object = .{
                .entry = .{
                    .parent = &cur.object.object,
                    .name = next_object.name[0..entry.name.len],
                },
                .data = switch (entry.kind) {
                    .directory => .{ .directory = null },
                    .sym_link => .{ .symlink = undefined },
                    else => .{ .file = undefined },
                },
            };

            try cur.object.object.insertChild(&next_object.object);

            cur.object_iter.current = cur.object.object.data.directory;
        };

        while (cur.object_iter.next()) |object| {
            try writeTokens(writer, &.{.directory_entry});
            try strWriter(object.entry.?.name, writer);
            try writeTokens(writer, &.{.directory_entry_inner});

            switch (object.data) {
                .directory => {
                    try writeTokens(writer, &.{.directory});
                    try iterators.ensureUnusedCapacity(1);
                    const next_dir = try cur.dir_iter.dir.openDir(object.entry.?.name, .{ .iterate = true });

                    const next = iterators.addOneAssumeCapacity();
                    next.* = .{
                        .object = @fieldParentPtr("object", object),
                        .dir_iter = next_dir.iterateAssumeFirstIteration(),
                    };
                    continue :next_dir;
                },
                .file => {
                    const stat = try cur.dir_iter.dir.statFile(object.entry.?.name);
                    try writeTokens(writer, &.{.file});
                    if (stat.mode & 0o111 != 0) try writeTokens(writer, &.{.executable_file});
                    try writeTokens(writer, &.{.file_contents});

                    try writer.writeInt(u64, stat.size, .little);
                    var left = stat.size;

                    var file = try cur.dir_iter.dir.openFile(object.entry.?.name, .{});
                    defer file.close();

                    while (left != 0) {
                        var buf: [4096 * 8]u8 = undefined;
                        const read = try file.read(&buf);
                        try writer.writeAll(buf[0..read]);
                        left -= read;
                    }

                    const zeroes: [8]u8 = .{0} ** 8;
                    try writer.writeAll(zeroes[0..@intCast((8 - stat.size % 8) % 8)]);
                },
                .symlink => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    try writeTokens(writer, &.{.symlink});

                    const link = try cur.dir_iter.dir.readLink(object.entry.?.name, &buf);

                    try strWriter(link, writer);
                },
            }
            try writeTokens(writer, &.{.directory_entry_end});
            objects.destroy(@fieldParentPtr("object", object));
        } else while (cur.object_iter.current == null) {
            if (cur.object.object.entry == null) break :next_dir;
            try writeTokens(writer, &.{.directory_entry_end});
            cur.dir_iter.dir.close();

            objects.destroy(cur.object);
            _ = iterators.pop().?;

            cur = &iterators.buffer[iterators.len - 1];
        }
    }
    try writeTokens(writer, &.{.archive_end});
}

/// Takes a file and serializes it as a Nix Archive into `writer`. This is faster and more
/// memory-efficient than calling `fromFileContents` followed by `dump`.
pub fn dumpFile(file: std.fs.File, executable: ?bool, writer: anytype) !void {
    const stat = try file.stat();
    const is_executable = executable orelse (stat.mode & 0o111 != 0);
    try writeTokens(writer, &.{ .magic, .file });
    if (is_executable) try writeTokens(writer, &.{.executable_file});
    try writeTokens(writer, &.{.file_contents});

    try writer.writeInt(u64, stat.size, .little);

    var left = stat.size;
    var buf: [4096]u8 = undefined;

    while (left != 0) {
        const read = try file.read(&buf);
        if (read == 0) return error.UnexpectedEof;
        try writer.writeAll(buf[0..read]);
        left -= read;
    }

    const zeroes: [8]u8 = .{0} ** 8;
    try writer.writeAll(zeroes[0..@intCast((8 - stat.size % 8) % 8)]);

    try writeTokens(writer, &.{.archive_end});
}

pub fn dumpSymlink(target: []const u8, writer: anytype) !void {
    try writeTokens(writer, &.{ .magic, .symlink });
    try strWriter(target, writer);
    try writeTokens(writer, &.{.archive_end});
}

pub const Object = struct {
    /// 0 for the root node
    parent: u32,
    prev: Index = .from(null),
    next: Index = .from(null),
    data: Data,
    name_index: u32,
    /// 0 for
    name_len: u32,

    pub const Data = union(enum) {
        regular_file: []u8,
        executable_file: []u8,
        symlink: struct { index: u32, len: u32 },
        directory: Index,
    };

    const Index = enum(u32) {
        _,

        pub fn from(i: ?u32) Index {
            std.debug.assert(i != 0);
            return @enumFromInt(i orelse 0);
        }

        pub fn index(self: Index) ?u32 {
            return if (self) |i| @intFromEnum(i) else null;
        }
    };

    pub fn insertChild(self: *Object, child: *Object) error{DuplicateObjectName}!void {
        if (self.data.directory) |first|
            switch (mem.order(u8, first.entry.?.name, child.entry.?.name)) {
                .lt => {
                    var left = first;
                    while (left.entry.?.next != null and mem.order(u8, left.entry.?.name, child.entry.?.name) == .lt) {
                        left = left.entry.?.next.?;
                    } else switch (mem.order(u8, left.entry.?.name, child.entry.?.name)) {
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
                    self.data.directory = child;
                },
            }
        else
            self.data.directory = child;
    }

    /// Traverses an Object, following symbolic links.
    pub fn subPath(self: *Object, subpath: []const u8) !*Object {
        var cur = self;
        var parts: std.BoundedArray([]const u8, 4096) = .{};
        parts.appendAssumeCapacity(subpath);

        comptime std.debug.assert(std.fs.path.sep == '/');
        while (parts.pop()) |full_first_path| {
            const first_part_len = std.mem.indexOfScalar(u8, full_first_path, '/');
            const first = if (first_part_len) |len| full_first_path[0..len] else full_first_path;
            const rest = if (first_part_len) |len| full_first_path[len + 1 ..] else "";
            if (rest.len != 0) parts.appendAssumeCapacity(rest);

            if (std.mem.eql(u8, first, ".") or first.len == 0) continue;
            if (std.mem.eql(u8, first, "..")) {
                if (cur.entry) |entry| cur = entry.parent;
                continue;
            }

            cur = if (cur.data == .directory)
                cur.data.directory orelse return error.FileNotFound
            else
                @panic(cur.entry.?.name);
            find: while (true) {
                switch (std.mem.order(u8, cur.entry.?.name, first)) {
                    .lt => {},
                    .eq => break :find,
                    .gt => return error.FileNotFound,
                }
                cur = cur.entry.?.next orelse return error.FileNotFound;
            }
            switch (cur.data) {
                .directory => {},
                .file => if (parts.len != 0) return error.IsFile,
                .symlink => |target| {
                    if (std.mem.startsWith(u8, target, "/")) return error.PathOutsideArchive;
                    try parts.append(target);
                    cur = cur.entry.?.parent;
                },
            }
        }
        return cur;
    }
};

pub const EncodeError = std.mem.Allocator.Error || error{
    UnexpectedToken,
    InvalidToken,
    WrongDirectoryOrder,
    DuplicateObjectName,
    NotANar,
    NameTooLarge,
    NameTooSmall,
};

const Token = enum {
    magic,
    archive_end,
    directory,
    regular_file,
    executable_file,
    symlink,
    directory_entry,
    directory_entry_inner,
    directory_entry_end,
};

const token_map = std.StaticStringMap(Token).initComptime(.{
    .{ str("nix-archive-1") ++ str("("), .magic },
    .{ str(")"), .archive_end },
    .{ str("type") ++ str("directory"), .directory },
    .{ str("type") ++ str("regular") ++ str("contents"), .regular_file },
    .{ str("type") ++ str("symlink") ++ str("target"), .symlink },
    .{ str("type") ++ str("regular") ++ str("") ++ str("executable") ++ str(""), .executable_file },
    .{ str("entry") ++ str("(") ++ str("name"), .directory_entry },
    .{ str(")") ++ str(")"), .directory_entry_end },
    .{ str("node") ++ str("("), .directory_entry_inner },
});

fn getTokenString(comptime value: Token) []const u8 {
    const values = token_map.values();
    const index = std.mem.indexOfScalar(Token, values, value).?;

    return token_map.keys()[index];
}

fn matches(slice: *[]u8, comptime token: Token) bool {
    return if (expectToken(slice, token)) |_| true else |_| false;
}

fn expectToken(slice: *[]u8, comptime token: Token) !void {
    //std.debug.print("Trying to match token {} ", .{token});
    if (matchAndSlide(slice, getTokenString(token))) {
        //std.debug.print("YES\n", .{});
    } else {
        //std.debug.print("NO\n", .{});
        return error.UnexpectedToken;
    }
}

fn writeTokens(writer: anytype, comptime tokens: []const Token) !void {
    comptime var concatenated: []const u8 = "";

    comptime {
        for (tokens) |token| concatenated = concatenated ++ getTokenString(token);
    }

    try writer.writeAll(concatenated);
}

/// Compares the start of a slice and a comptime-known match, and advances the slice if it matches.
fn matchAndSlide(slice: *[]u8, comptime match: []const u8) bool {
    if (match.len % 8 != 0) @compileError("match is not a multiple of 8 and is of size " ++
        std.fmt.digits2(@intCast(match.len)));

    if (slice.len < match.len) return false;

    const matched = mem.eql(u8, slice.*[0..match.len], match);
    if (matched) slice.* = slice.*[match.len..];
    return matched;
}

fn unstr(slice: *[]u8) EncodeError![]u8 {
    if (slice.len < 8) return error.InvalidToken;

    const len = std.math.cast(usize, mem.readInt(u64, slice.*[0..8], .little)) orelse return error.OutOfMemory;
    const padded_len = (divCeil(usize, len, 8) catch unreachable) * 8;

    if (slice.*[8..].len < padded_len) return error.InvalidToken;

    slice.* = slice.*[8..];

    const result = slice.*[0..len];

    if (!mem.allEqual(u8, slice.*[len..padded_len], 0)) return error.InvalidToken;

    slice.* = slice.*[padded_len..];

    return result;
}

fn strWriter(string: []const u8, writer: anytype) !void {
    var buffer: [8]u8 = undefined;
    mem.writeInt(u64, &buffer, string.len, .little);

    const zeroes: [7]u8 = .{0} ** 7;

    try writer.print("{s}{s}{s}", .{ &buffer, string, zeroes[0 .. (8 - string.len % 8) % 8] });
}

fn str(comptime string: anytype) []const u8 {
    comptime {
        var buffer: [8]u8 = undefined;
        mem.writeInt(u64, &buffer, string.len, .little);

        const zeroes: [7]u8 = .{0} ** 7;
        return buffer ++ string ++ (if (string.len % 8 == 0) [0]u8{} else zeroes[0 .. (8 - string.len % 8) % 8]);
    }
}

test "single file" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/README.nar")));
    defer data.deinit();

    try expectEqualStrings(@embedFile("tests/README.out"), data.root.data.file.contents);
}

test "directory containing a single file" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/hello.nar")));
    defer data.deinit();

    const dir = data.root;
    const file = dir.data.directory.?;
    try expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.file.contents);
    try expectEqualStrings("main.zig", file.entry.?.name);
}

test "a file, a directory, and some more files" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/dir-and-files.nar")));
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try expectEqualStrings("dir", dir.entry.?.name);

    const file1 = dir.entry.?.next.?;
    try expectEqual(file1.entry.?.next, null);
    try expectEqualStrings("file1", file1.entry.?.name);
    try expectEqual(false, file1.data.file.is_executable);
    try expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try expectEqualStrings("file2", file2.entry.?.name);
    try expectEqual(true, file2.data.file.is_executable);
    try expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.entry.?.next.?;
    try expectEqual(false, file3.data.file.is_executable);
    try expectEqualStrings("file3", file3.entry.?.name);
    try expectEqualStrings("nevermind\n", file3.data.file.contents);
    try expectEqual(null, file3.entry.?.next);
}

test "a symlink" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/symlink.nar")));
    defer data.deinit();

    try expectEqualStrings("README.out", data.root.data.symlink);
}

test "nar from dir-and-files" {
    const allocator = std.testing.allocator;

    var root = try std.fs.cwd().openDir(tests_path ++ "/dir-and-files", .{ .iterate = true });
    defer root.close();

    var data = try NarArchive.fromDirectory(allocator, root);
    defer data.deinit();

    const dir = data.root.data.directory.?;
    try expectEqualStrings("dir", dir.entry.?.name);

    const file1 = dir.entry.?.next.?;
    try expectEqual(null, file1.entry.?.next);
    try expectEqualStrings("file1", file1.entry.?.name);
    try expectEqual(false, file1.data.file.is_executable);
    try expectEqualStrings("hi\n", file1.data.file.contents);

    const file2 = dir.data.directory.?;
    try expectEqualStrings("file2", file2.entry.?.name);
    try expectEqual(true, file2.data.file.is_executable);
    try expectEqualStrings("bye\n", file2.data.file.contents);

    const file3 = file2.entry.?.next.?;
    try expectEqual(false, file3.data.file.is_executable);
    try expectEqualStrings("file3", file3.entry.?.name);
    try expectEqualStrings("nevermind\n", file3.data.file.contents);
    try expectEqual(null, file3.entry.?.next);
}

test "empty directory" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/empty", .{ .iterate = true });
    defer root.close();

    var data = try NarArchive.fromDirectory(allocator, root);
    defer data.deinit();

    try expectEqual(null, data.root.data.directory);
}

test "nar to directory to nar" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/dir-and-files.nar")));
    defer data.deinit();

    const expected = @embedFile("tests/dir-and-files.nar");

    var buffer: [2 * expected.len]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try data.dump(stream.writer());

    try std.testing.expectEqualSlices(u8, expected, stream.getWritten());
}

test "more complex" {
    const allocator = std.testing.allocator;

    std.fs.cwd().makeDir(tests_path ++ "/complex/empty") catch {};

    var root = try std.fs.cwd().openDir(tests_path ++ "/complex", .{ .iterate = true });
    defer root.close();

    const expected = @embedFile("tests/complex.nar") ** 3 ++
        @embedFile("tests/complex_empty.nar") ** 2;

    var array: std.BoundedArray(u8, 2 * expected.len) = .{};
    const writer = array.writer();

    {
        try dumpDirectory(allocator, root, writer);

        var archive = try NarArchive.fromDirectory(allocator, root);
        defer archive.deinit();

        try archive.dump(writer);

        const contents: []u8 = @constCast(@embedFile("tests/complex.nar"));

        var other_archive = try NarArchive.fromSlice(allocator, contents);
        defer other_archive.deinit();

        try other_archive.dump(writer);
    }
    {
        var empty = try root.openDir("empty", .{ .iterate = true });
        defer empty.close();

        try dumpDirectory(allocator, empty, writer);

        var archive = try NarArchive.fromDirectory(allocator, empty);
        defer archive.deinit();

        try archive.dump(writer);
    }

    // TODO: Add more dumps and froms
    try std.testing.expectEqualSlices(u8, expected, array.slice());
}

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}
