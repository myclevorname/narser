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
/// 1. The object pointed to by root must have a null `prev`, `next`, and its name is undefined.
///
/// 2. The object a directory points to must have a non-null entry, have no previous object, and
/// has a parent set to said directory.
///
/// 3. All objects in a directory must be sorted by name and must be unique within a directory.
///
/// 4. The root node is the first node in the node list.
pub const NarArchive = struct {
    allocator: std.mem.Allocator,
    contents_arena: std.heap.ArenaAllocator,
    name_arena: std.heap.MemoryPool([std.fs.max_path_bytes]u8),
    node_list: std.ArrayListAlignedUnmanaged(Object, 32),
    free_list: std.ArrayListUnmanaged(u32),

    /// Takes ownership of a slice representing a Nix archive and deserializes it.
    /// Guaranteed to not modify the slice if an error occurs.
    pub fn fromSlice(allocator: std.mem.Allocator, slice: []u8) EncodeError!NarArchive {
        var self: NarArchive = .{
            .allocator = allocator,
            .contents_arena = .init(allocator),
            .name_arena = .init(allocator),
            .node_list = .empty,
            .free_list = .empty,
        };
        errdefer self.deinit();

        var stream = slice;

        var index: u32 = 0;
        try self.node_list.resize(self.allocator, 1);
        self.node_list.items[index] = .{
            .parent = 0,
            .name = undefined,
            .prev = .null,
            .next = .null,
            .data = undefined,
        };

        const items = &self.node_list.items;

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
                items.*[index].name = try unstr(&stream);
                switch (items.*[index].prev) {
                    .null => {},
                    _ => |x| switch (std.mem.order(u8, items.*[@intFromEnum(x)].name, items.*[index].name)) {
                        .lt => {},
                        .eq => return error.DuplicateObjectName,
                        .gt => return error.WrongDirectoryOrder,
                    },
                }
                try expectToken(&stream, .directory_entry_inner);
                continue :state .get_object_type;
            },
            .directory => {
                items.*[index].data = .{ .directory = .null };
                if (index != 0) {
                    if (matches(&stream, .directory_entry_end)) continue :state .next_skip_end;
                } else {
                    if (matches(&stream, .archive_end)) {
                        if (stream.len != 0) return error.InvalidFormat else break :state;
                    }
                }

                // there must be a child at this point

                const child = try self.node_list.addOne(self.allocator);
                items.*[index].data.directory = @enumFromInt(items.*.len - 1);
                child.* = .{
                    .parent = index,
                    .prev = .null,
                    .next = .null,
                    .name = undefined,
                    .data = undefined,
                };
                index = @intCast(items.*.len - 1);
                continue :state .get_entry;
            },
            .file => {
                items.*[index].data = if (blk: {
                    const v = matches(&stream, .executable_file);
                    try expectToken(&stream, .file_contents);
                    break :blk v;
                })
                    .{ .executable_file = try unstr(&stream) }
                else
                    .{ .non_executable_file = try unstr(&stream) };
                continue :state .next;
            },
            .symlink => {
                items.*[index].data = .{ .symlink = try unstr(&stream) };
                continue :state .next;
            },
            .next => {
                if (index != 0) {
                    try expectToken(&stream, .directory_entry_end);
                    continue :state .leave_directory;
                } else continue :state .end;
            },
            .next_skip_end => {
                continue :state (if (index != 0) .leave_directory else .end);
            },
            .leave_directory => {
                while (index != 0 and matches(&stream, .directory_entry_end)) {
                    index = items.*[index].parent;
                } else {
                    if (index != 0 and matches(&stream, .directory_entry)) {
                        const next = try self.node_list.addOne(self.allocator);
                        const next_index: u32 = @intCast(items.*.len - 1);
                        items.*[index].next = @enumFromInt(next_index);
                        next.* = .{
                            .parent = self.node_list.items[index].parent,
                            .prev = @enumFromInt(index),
                            .next = .null,
                            .name = undefined,
                            .data = undefined,
                        };
                        index = next_index;
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
            .allocator = allocator,
            .contents_arena = .init(allocator),
            .name_pool = .init(allocator),
            .node_list = .init(allocator),
            .free_list = .init(allocator),
        };
        errdefer self.deinit();

        {
            const root_node = try self.node_list.addOne(self.allocator);
            root_node.* = .{
                .parent = 0,
                .prev = .null,
                .next = .null,
                .name = undefined,
                .data = .{ .directory = .null },
            };
        }

        var iters: std.BoundedArray(struct {
            iterator: std.fs.Dir.Iterator, // holds the directory
            object: u32,
        }, 256) = .{};

        iters.appendAssumeCapacity(.{
            .iterator = root.iterate(),
            .object = 0,
        });

        errdefer if (iters.len > 1) for (iters.slice()[1..]) |*x| x.iterator.dir.close();

        while (iters.len != 0) {
            var cur = &iters.slice()[iters.len - 1];
            const entry = try cur.iterator.next();

            if (entry) |e| {
                const next = try self.node_list.addOne(self.allocator);
                next.* = .{
                    .parent = cur.object,
                    .prev = .null,
                    .next = .null,
                    .name = blk: {
                        const name = try self.name_pool.create();
                        @memcpy(name[0..e.name.len], e.name);
                        break :blk name;
                    },
                    .data = undefined,
                };
                switch (e.kind) {
                    .directory => {
                        next.data = .{ .directory = .null };
                        var child = try cur.iterator.dir.openDir(e.name, .{ .iterate = true });
                        iters.append(.{
                            .iterator = child.iterateAssumeFirstIteration(),
                            .object = @intCast(self.node_list.items.len - 1),
                        }) catch return error.NestedTooDeep;
                    },
                    .sym_link => {
                        next.data = .{ .symlink = undefined };
                        const buf = try self.name_pool.create();
                        const link = try cur.iterator.dir.readLink(e.name, buf);
                        next.data.symlink = try self.name_arena.allocator().dupe(u8, link);
                    },
                    else => {
                        const stat = try cur.iterator.dir.statFile(e.name);
                        const contents = try cur.iterator.dir.readFileAllocOptions(
                            self.contents_arena.allocator(),
                            e.name,
                            std.math.maxInt(usize),
                            std.math.cast(usize, stat.size) orelse std.math.maxInt(usize),
                            1,
                            null,
                        );
                        next.data = switch (stat.mode & 1 == 1) {
                            true => .{ .executable_file = contents },
                            false => .{ .non_executable_file = contents },
                        };
                    },
                }
                try Object.insertChild(&self, cur.object, self.node_list.items.len - 1);
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
        contents: []u8,
        is_executable: bool,
    ) std.mem.Allocator.Error!NarArchive {
        const self = .{
            .allocator = allocator,
            .contents_arena = .init(allocator),
            .name_pool = .init(allocator),
            .node_list = .init(allocator),
            .free_list = .init(allocator),
        };
        errdefer self.deinit();

        const node = try self.node_list.addOne(allocator);

        node.* = .{
            .parent = 0,
            .prev = .null,
            .next = .null,
            .data = if (is_executable)
                .{ .executable_file = contents }
            else
                .{ .non_executable_file = contents },
        };

        return self;
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
    pub fn dump(self: *const NarArchive, writer: anytype) !void {
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

    pub fn new_node(self: *NarArchive) std.mem.Allocator.Error!u32 {
        return self.free_list.pop() orelse blk: {
            _ = try self.node_list.addOne();
            break :blk self.node_list.items.len - 1;
        };
    }

    pub fn deinit(self: *NarArchive) void {
        self.node_list.deinit(self.allocator);
        self.name_arena.deinit();
        self.free_list.deinit(self.allocator);
        self.* = undefined;
        @panic("TODO");
    }
};

/// Takes a directory and serializes it as a Nix Archive into `writer`. This is faster and more
/// memory-efficient than calling `fromDirectory` followed by `dump`.
pub fn dumpDirectory(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    writer: anytype,
) !void {
    _, _, _ = .{ allocator, root_dir, writer };
    @panic("TODO: dumpDirectory");
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
    /// This will be zero for the root object, so you must make sure the index of this object is 0.
    parent: u32,
    prev: Index,
    next: Index,
    /// This is undefined for the root object.
    name: []u8,
    data: Data,

    pub const Index = enum(u32) {
        null,
        _,
        pub fn index(self: Index) ?u32 {
            return switch (self) {
                .null => null,
                _ => |x| @intFromEnum(x),
            };
        }
    };

    pub const Data = union(enum) {
        non_executable_file: []u8,
        executable_file: []u8,
        symlink: []u8,
        directory: Index,
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

    try expectEqualStrings(
        @embedFile("tests/README.out"),
        data.node_list.items[0].data.non_executable_file,
    );
}

test "directory containing a single file" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/hello.nar")));
    defer data.deinit();

    const dir = data.node_list.items[0];
    const file = switch (dir.data.directory) {
        .null => return error.NullIndex,
        _ => |x| data.node_list.items[@intFromEnum(x)],
    };
    try expectEqualStrings(@embedFile("tests/hello.zig.out"), file.data.non_executable_file);
    try expectEqualStrings("main.zig", file.name);
}

test "a file, a directory, and some more files" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/dir-and-files.nar")));
    defer data.deinit();

    const list = data.node_list.items;

    const dir = switch (list[0].data.directory) {
        .null => return error.NullIndex,
        _ => |x| @intFromEnum(x),
    };
    try expectEqualStrings("dir", list[dir].name);

    const file1 = switch (list[dir].next) {
        .null => return error.NullIndex,
        _ => |x| @intFromEnum(x),
    };
    try expectEqual(list[file1].next, .null);
    try expectEqualStrings("file1", list[file1].name);
    try expectEqualStrings("hi\n", list[file1].data.non_executable_file);

    const file2 = switch (list[dir].data.directory) {
        .null => return error.NullIndex,
        _ => |x| list[@intFromEnum(x)],
    };
    try expectEqualStrings("file2", file2.name);
    try expectEqualStrings("bye\n", file2.data.executable_file);

    const file3 = switch (file2.next) {
        .null => return error.NullIndex,
        _ => |x| list[@intFromEnum(x)],
    };
    try expectEqualStrings("file3", file3.name);
    try expectEqualStrings("nevermind\n", file3.data.non_executable_file);
    try expectEqual(.null, file3.next);
}

test "a symlink" {
    const allocator = std.testing.allocator;

    var data = try NarArchive.fromSlice(allocator, @constCast(@embedFile("tests/symlink.nar")));
    defer data.deinit();

    try expectEqualStrings("README.out", data.node_list.items[0].data.symlink);
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

test { _ = std.testing.refAllDeclsRecursive(); }

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
