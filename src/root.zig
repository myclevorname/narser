const std = @import("std");
const tests_path = @import("tests").tests_path;

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const mem = std.mem;
const divCeil = std.math.divCeil;

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
    arena: std.heap.ArenaAllocator,
    pool: std.heap.MemoryPool(Object),
    root: *Object,

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self: NarArchive = .{
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
        };
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        var stream = slice;

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
                expectToken(&stream, .magic) catch return error.NotANar;

                continue :state .get_object_type;
            },
            .get_object_type => {
                if (matches(&stream, .file))
                    continue :state .file
                else if (matches(&stream, .directory))
                    continue :state .directory
                else if (matches(&stream, .symlink))
                    continue :state .symlink
                else
                    return error.InvalidFormat;
            },
            .get_entry => {
                try expectToken(&stream, .directory_entry);
                continue :state .get_entry_inner;
            },
            .get_entry_inner => {
                current.entry.?.name = try unstr(&stream);
                if (current.entry.?.prev) |p| switch (std.mem.order(u8, p.entry.?.name, current.entry.?.name)) {
                    .lt => {},
                    .eq => return error.DuplicateObjectName,
                    .gt => return error.WrongDirectoryOrder,
                };
                try expectToken(&stream, .directory_entry_inner);
                continue :state .get_object_type;
            },
            .directory => {
                current.data = .{ .directory = null };
                if (current.entry != null) {
                    if (matches(&stream, .directory_entry_end)) continue :state .next_skip_end;
                } else {
                    if (matches(&stream, .archive_end)) {
                        if (stream.len != 0) return error.InvalidFormat else break :state;
                    }
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
                if (matches(&stream, .executable_file)) current.data.file.is_executable = true;
                try expectToken(&stream, .file_contents);
                current.data.file.contents = try unstr(&stream);
                continue :state .next;
            },
            .symlink => {
                current.data = .{ .symlink = try unstr(&stream) };
                continue :state .next;
            },
            .next => {
                if (current.entry != null) {
                    try expectToken(&stream, .directory_entry_end);
                    continue :state .leave_directory;
                } else continue :state .end;
            },
            .next_skip_end => {
                continue :state (if (current.entry != null) .leave_directory else .end);
            },
            .leave_directory => {
                while (current.entry != null and matches(&stream, .directory_entry_end)) {
                    current = current.entry.?.parent;
                } else {
                    if (current.entry != null and matches(&stream, .directory_entry)) {
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
            .arena = .init(allocator),
            .pool = undefined,
            .root = undefined,
        };
        self.pool = .init(self.arena.allocator());
        errdefer self.deinit();

        const root_node = try self.pool.create();
        root_node.* = .{
            .entry = null,
            .data = .{ .directory = null },
        };
        self.root = root_node;

        var iters: std.BoundedArray(struct {
            iterator: std.fs.Dir.Iterator, // holds the directory
            object: *Object,
        }, 256) = .{};

        iters.appendAssumeCapacity(.{
            .iterator = root.iterate(),
            .object = root_node,
        });

        errdefer if (iters.len > 1) for (iters.slice()[1..]) |*x| x.iterator.dir.close();

        while (iters.len != 0) {
            var cur = &iters.slice()[iters.len - 1];
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
                        iters.append(.{
                            .iterator = child.iterate(),
                            .object = next,
                        }) catch @panic("Implementation limit reached: Directory nested too deeply");
                    },
                    .sym_link => {
                        next.*.data = .{ .symlink = undefined };
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        const link = try cur.iterator.dir.readLink(e.name, &buf);
                        next.data.symlink = try self.arena.allocator().dupe(u8, link);
                    },
                    else => {
                        next.*.data = .{ .file = undefined };
                        const stat = try cur.iterator.dir.statFile(e.name);
                        const contents = try cur.iterator.dir.readFileAllocOptions(
                            self.arena.allocator(),
                            e.name,
                            std.math.maxInt(usize),
                            std.math.cast(usize, stat.size) orelse std.math.maxInt(usize),
                            .of(u8),
                            null,
                        );
                        next.data.file = .{
                            .contents = contents,
                            .is_executable = stat.mode & 1 == 1,
                        };
                    },
                }
                try cur.object.insertChild(next);
            } else {
                if (iters.len > 1) cur.iterator.dir.close();
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
    ) std.mem.Allocator.Error!NarArchive {
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
        };
    }

    /// Creates a NAR archive containing a single symlink given its target.
    pub fn fromSymlink(
        allocator: std.mem.Allocator,
        target: []const u8,
    ) std.mem.Allocator.Error!NarArchive {
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
        };
    }

    /// Serialize a NarArchive into the writer.
    pub fn dump(self: *const NarArchive, writer: *std.Io.Writer) !void {
        var node = self.root;

        try writeTokens(writer, &.{.magic});

        loop: while (true) {
            if (node.entry != null) {
                try writeTokens(writer, &.{.directory_entry});
                try strWriter(node.entry.?.name, writer);
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
                    try strWriter(data.contents, writer);
                },
                .symlink => |link| {
                    try writeTokens(writer, &.{.symlink});
                    try strWriter(link, writer);
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
    pub fn unpackDir(self: *const NarArchive, target_dir: std.fs.Dir) !void {
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

    pub fn deinit(self: *NarArchive) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Takes a directory and serializes it as a Nix Archive into `writer`. This is faster and more
/// memory-efficient than calling `fromDirectory` followed by `dump`.
pub fn dumpDirectory(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    writer: *std.Io.Writer,
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

    const Iterator = struct {
        dir_iter: std.fs.Dir.Iterator,
        object: *NamedObject,
        object_iter: ObjectIterator = .{},
    };

    var iters_buf: [256]Iterator = undefined;
    var iterators: std.ArrayListUnmanaged(Iterator) = .initBuffer(&iters_buf);
    defer if (iterators.items.len > 1) for (iterators.items[1..]) |*iter| iter.dir_iter.dir.close();

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
        var cur = &iterators.items[iterators.items.len - 1];

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
                    const next = try iterators.addOneBounded();
                    errdefer _ = iterators.pop().?;

                    const next_dir = try cur.dir_iter.dir.openDir(object.entry.?.name, .{ .iterate = true });
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

            cur = &iterators.items[iterators.items.len - 1];
        }
    }
    try writeTokens(writer, &.{.archive_end});
}

/// Takes a file and serializes it as a Nix Archive into `writer`. This is faster and more
/// memory-efficient than calling `fromFileContents` followed by `dump`.
pub fn dumpFile(file: std.fs.File, executable: ?bool, writer: *std.Io.Writer) !void {
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

pub fn dumpSymlink(target: []const u8, writer: *std.Io.Writer) !void {
    try writeTokens(writer, &.{ .magic, .symlink });
    try strWriter(target, writer);
    try writeTokens(writer, &.{.archive_end});
}

pub const Object = struct {
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
        var parts_buf: [4096][]const u8 = undefined;
        var parts: std.ArrayListUnmanaged([]const u8) = .initBuffer(&parts_buf);
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
                .file => if (parts.items.len != 0) return error.IsFile,
                .symlink => |target| {
                    if (std.mem.startsWith(u8, target, "/")) return error.PathOutsideArchive;
                    parts.appendBounded(target) catch return error.NestedTooDeep;
                    cur = cur.entry.?.parent;
                },
            }
        }
        return cur;
    }
};

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidFormat,
    WrongDirectoryOrder,
    DuplicateObjectName,
    NotANar,
};

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
        return error.InvalidFormat;
    }
}

fn writeTokens(writer: *std.Io.Writer, comptime tokens: []const Token) !void {
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
    if (slice.len < 8) return error.InvalidFormat;

    const len = std.math.cast(usize, mem.readInt(u64, slice.*[0..8], .little)) orelse return error.OutOfMemory;
    const padded_len = (divCeil(usize, len, 8) catch unreachable) * 8;

    if (slice.*[8..].len < padded_len) return error.InvalidFormat;

    slice.* = slice.*[8..];

    const result = slice.*[0..len];

    if (!mem.allEqual(u8, slice.*[len..padded_len], 0)) return error.InvalidFormat;

    slice.* = slice.*[padded_len..];

    return result;
}

fn strWriter(string: []const u8, writer: *std.Io.Writer) !void {
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
    var updated = stream.writer().adaptToNewApi();

    try data.dump(&updated.new_interface);

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
    var updated = array.writer().adaptToNewApi();
    const writer = &updated.new_interface;

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
