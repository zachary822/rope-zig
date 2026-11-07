const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_leaf: usize = 1024;

const Node = union(enum) {
    leaf: std.ArrayList(u8),
    branch: Branch,

    const Branch = struct {
        left: *Node,
        right: *Node,
        len: usize,
        height: u32,
    };

    fn len(node: *const Node) usize {
        return switch (node.*) {
            .leaf => |leaf| leaf.items.len,
            .branch => |branch| branch.len,
        };
    }

    fn height(node: *const Node) u32 {
        return switch (node.*) {
            .leaf => 0,
            .branch => |branch| branch.height,
        };
    }

    fn createLeaf(mem: Mem, text: []const u8) Allocator.Error!*Node {
        std.debug.assert(text.len > 0 and text.len <= max_leaf);
        const node = try mem.nodes.create(mem.gpa);
        errdefer mem.nodes.destroy(node);
        var list: std.ArrayList(u8) = try .initCapacity(mem.gpa, text.len);
        list.appendSliceAssumeCapacity(text);
        node.* = .{ .leaf = list };
        return node;
    }

    fn createBranch(mem: Mem, left: *Node, right: *Node) Allocator.Error!*Node {
        const node = try mem.nodes.create(mem.gpa);
        node.* = .{ .branch = .{ .left = left, .right = right, .len = 0, .height = 0 } };
        node.update();
        return node;
    }

    fn update(node: *Node) void {
        const branch = &node.branch;
        branch.len = branch.left.len() + branch.right.len();
        branch.height = 1 + @max(branch.left.height(), branch.right.height());
    }

    fn counted(node: *Node) *Counted {
        return @fieldParentPtr("node", node);
    }

    fn retain(node: *Node) *Node {
        node.counted().refs += 1;
        return node;
    }

    fn isShared(node: *const Node) bool {
        const c: *const Counted = @fieldParentPtr("node", node);
        return c.refs > 1;
    }

    fn release(node: *Node, mem: Mem) void {
        const c = node.counted();
        c.refs -= 1;
        if (c.refs > 0) return;
        switch (node.*) {
            .leaf => |*leaf| leaf.deinit(mem.gpa),
            .branch => |branch| {
                branch.left.release(mem);
                branch.right.release(mem);
            },
        }
        mem.nodes.destroy(node);
    }

    fn own(node: *Node, mem: Mem) Allocator.Error!*Node {
        if (!node.isShared()) return node;
        const copy = switch (node.*) {
            .leaf => |leaf| try createLeaf(mem, leaf.items),
            .branch => |branch| try createBranch(mem, branch.left, branch.right),
        };
        if (copy.* == .branch) {
            _ = copy.branch.left.retain();
            _ = copy.branch.right.retain();
        }
        node.release(mem);
        return copy;
    }

    fn unwrap(node: *Node, mem: Mem) struct { *Node, *Node } {
        const left = node.branch.left;
        const right = node.branch.right;
        if (node.isShared()) {
            _ = left.retain();
            _ = right.retain();
            node.release(mem);
        } else {
            mem.nodes.destroy(node);
        }
        return .{ left, right };
    }
};

const Counted = struct {
    refs: u32,
    node: Node,
};

const NodePool = struct {
    pool: std.heap.MemoryPool(Counted) = .empty,
    live: usize = 0,

    fn create(nodes: *NodePool, gpa: Allocator) Allocator.Error!*Node {
        const c = try nodes.pool.create(gpa);
        c.refs = 1;
        nodes.live += 1;
        return &c.node;
    }

    fn destroy(nodes: *NodePool, node: *Node) void {
        nodes.pool.destroy(node.counted());
        nodes.live -= 1;
    }

    fn deinit(nodes: *NodePool, gpa: Allocator) void {
        nodes.pool.deinit(gpa);
        nodes.* = undefined;
    }
};

const Mem = struct {
    gpa: Allocator,
    nodes: *NodePool,
};

fn build(mem: Mem, text: []const u8) Allocator.Error!*Node {
    std.debug.assert(text.len > 0);
    if (text.len <= max_leaf) return Node.createLeaf(mem, text);
    const mid = text.len / 2;
    const left = try build(mem, text[0..mid]);
    errdefer left.release(mem);
    const right = try build(mem, text[mid..]);
    errdefer right.release(mem);
    return Node.createBranch(mem, left, right);
}

fn rotateLeft(mem: Mem, node: *Node) Allocator.Error!*Node {
    const pivot = try node.branch.right.own(mem);
    node.branch.right = pivot.branch.left;
    node.update();
    pivot.branch.left = node;
    pivot.update();
    return pivot;
}

fn rotateRight(mem: Mem, node: *Node) Allocator.Error!*Node {
    const pivot = try node.branch.left.own(mem);
    node.branch.left = pivot.branch.right;
    node.update();
    pivot.branch.right = node;
    pivot.update();
    return pivot;
}

fn rebalance(mem: Mem, node: *Node) Allocator.Error!*Node {
    node.update();
    const left = node.branch.left;
    const right = node.branch.right;
    if (left.height() > right.height() + 1) {
        if (left.branch.left.height() < left.branch.right.height()) {
            node.branch.left = try left.own(mem);
            node.branch.left = try rotateLeft(mem, node.branch.left);
        }
        return rotateRight(mem, node);
    }
    if (right.height() > left.height() + 1) {
        if (right.branch.right.height() < right.branch.left.height()) {
            node.branch.right = try right.own(mem);
            node.branch.right = try rotateRight(mem, node.branch.right);
        }
        return rotateLeft(mem, node);
    }
    return node;
}

fn mergeLeaves(mem: Mem, left: *Node, right: *Node) Allocator.Error!*Node {
    defer right.release(mem);
    if (!left.isShared()) {
        left.leaf.appendSlice(mem.gpa, right.leaf.items) catch |err| {
            left.release(mem);
            return err;
        };
        return left;
    }
    defer left.release(mem);
    const a = left.leaf.items;
    const b = right.leaf.items;
    var buf: [max_leaf]u8 = undefined;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return Node.createLeaf(mem, buf[0 .. a.len + b.len]);
}

fn joinNodes(mem: Mem, left: *Node, right: *Node) Allocator.Error!*Node {
    if (left.* == .leaf and right.* == .leaf and left.len() + right.len() <= max_leaf) {
        return mergeLeaves(mem, left, right);
    }
    if (left.height() > right.height() + 1) {
        const l = left.own(mem) catch |err| {
            left.release(mem);
            right.release(mem);
            return err;
        };
        l.branch.right = joinNodes(mem, l.branch.right, right) catch |err| {
            l.branch.left.release(mem);
            mem.nodes.destroy(l);
            return err;
        };
        return rebalance(mem, l) catch |err| {
            l.release(mem);
            return err;
        };
    }
    if (right.height() > left.height() + 1) {
        const r = right.own(mem) catch |err| {
            left.release(mem);
            right.release(mem);
            return err;
        };
        r.branch.left = joinNodes(mem, left, r.branch.left) catch |err| {
            r.branch.right.release(mem);
            mem.nodes.destroy(r);
            return err;
        };
        return rebalance(mem, r) catch |err| {
            left.release(mem);
            right.release(mem);
            return err;
        };
    }
    return Node.createBranch(mem, left, right) catch |err| {
        left.release(mem);
        right.release(mem);
        return err;
    };
}

fn join(mem: Mem, left: ?*Node, right: ?*Node) Allocator.Error!?*Node {
    const l = left orelse return right;
    const r = right orelse return l;
    return try joinNodes(mem, l, r);
}

fn split(mem: Mem, node: *Node, index: usize) Allocator.Error!struct { ?*Node, ?*Node } {
    switch (node.*) {
        .leaf => |*leaf| {
            if (index == 0) return .{ null, node };
            if (index == leaf.items.len) return .{ node, null };
            const right = Node.createLeaf(mem, leaf.items[index..]) catch |err| {
                node.release(mem);
                return err;
            };
            if (node.isShared()) {
                const left = Node.createLeaf(mem, leaf.items[0..index]) catch |err| {
                    right.release(mem);
                    node.release(mem);
                    return err;
                };
                node.release(mem);
                return .{ left, right };
            }
            leaf.shrinkRetainingCapacity(index);
            return .{ node, right };
        },
        .branch => {
            const left, const right = node.unwrap(mem);
            const weight = left.len();
            if (index < weight) {
                const a, const b = split(mem, left, index) catch |err| {
                    right.release(mem);
                    return err;
                };
                const rest = join(mem, b, right) catch |err| {
                    if (a) |n| n.release(mem);
                    return err;
                };
                return .{ a, rest };
            }
            if (index > weight) {
                const a, const b = split(mem, right, index - weight) catch |err| {
                    left.release(mem);
                    return err;
                };
                const first = join(mem, left, a) catch |err| {
                    if (b) |n| n.release(mem);
                    return err;
                };
                return .{ first, b };
            }

            return .{ left, right };
        },
    }
}

fn insertInPlace(gpa: Allocator, node: *Node, index: usize, text: []const u8) Allocator.Error!bool {
    if (node.isShared()) return false;
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.items.len + text.len > max_leaf) return false;
            try leaf.insertSlice(gpa, index, text);
            return true;
        },
        .branch => |*branch| {
            const weight = branch.left.len();
            const done = if (index <= weight)
                try insertInPlace(gpa, branch.left, index, text)
            else
                try insertInPlace(gpa, branch.right, index - weight, text);
            if (done) branch.len += text.len;
            return done;
        },
    }
}

fn deleteInPlace(node: *Node, start: usize, count: usize) bool {
    if (node.isShared()) return false;
    switch (node.*) {
        .leaf => |*leaf| {
            if (count >= leaf.items.len) return false;
            leaf.replaceRangeAssumeCapacity(start, count, &.{});
            return true;
        },
        .branch => |*branch| {
            const weight = branch.left.len();
            const done = if (start + count <= weight)
                deleteInPlace(branch.left, start, count)
            else if (start >= weight)
                deleteInPlace(branch.right, start - weight, count)
            else
                false;
            if (done) branch.len -= count;
            return done;
        },
    }
}

fn byteAtIn(root: ?*const Node, index: usize) u8 {
    var node = root.?;
    var i = index;
    while (true) {
        switch (node.*) {
            .leaf => |leaf| return leaf.items[i],
            .branch => |branch| {
                const weight = branch.left.len();
                if (i < weight) {
                    node = branch.left;
                } else {
                    i -= weight;
                    node = branch.right;
                }
            },
        }
    }
}

fn copyText(gpa: Allocator, root: ?*const Node) Allocator.Error![]u8 {
    const total = if (root) |r| r.len() else 0;
    const out = try gpa.alloc(u8, total);
    var pos: usize = 0;
    var it: Rope.ChunkIterator = .init(root);
    while (it.next()) |chunk| {
        @memcpy(out[pos..][0..chunk.len], chunk);
        pos += chunk.len;
    }
    return out;
}

fn writeText(writer: *Io.Writer, root: ?*const Node) Io.Writer.Error!void {
    var it: Rope.ChunkIterator = .init(root);
    while (it.next()) |chunk| try writer.writeAll(chunk);
}

pub const Snapshot = struct {
    root: ?*Node,

    pub fn len(snap: Snapshot) usize {
        const root = snap.root orelse return 0;
        return root.len();
    }

    pub fn byteAt(snap: Snapshot, index: usize) u8 {
        std.debug.assert(index < snap.len());
        return byteAtIn(snap.root, index);
    }

    pub fn chunks(snap: Snapshot) Rope.ChunkIterator {
        return .init(snap.root);
    }

    pub fn toOwnedSlice(snap: Snapshot, gpa: Allocator) Allocator.Error![]u8 {
        return copyText(gpa, snap.root);
    }

    pub fn format(snap: Snapshot, writer: *Io.Writer) Io.Writer.Error!void {
        return writeText(writer, snap.root);
    }
};

pub const Rope = struct {
    gpa: Allocator,
    root: ?*Node = null,
    nodes: NodePool = .{},

    pub fn init(gpa: Allocator) Rope {
        return .{ .gpa = gpa };
    }

    fn memory(rope: *Rope) Mem {
        return .{ .gpa = rope.gpa, .nodes = &rope.nodes };
    }

    pub fn fromSlice(gpa: Allocator, text: []const u8) Allocator.Error!Rope {
        var rope: Rope = .init(gpa);
        errdefer rope.nodes.deinit(gpa);
        if (text.len > 0) rope.root = try build(rope.memory(), text);
        return rope;
    }

    pub fn deinit(rope: *Rope) void {
        if (rope.root) |root| root.release(rope.memory());
        std.debug.assert(rope.nodes.live == 0);
        rope.nodes.deinit(rope.gpa);
        rope.* = undefined;
    }

    pub fn len(rope: *const Rope) usize {
        const root = rope.root orelse return 0;
        return root.len();
    }

    pub fn height(rope: *const Rope) u32 {
        const root = rope.root orelse return 0;
        return root.height();
    }

    pub fn byteAt(rope: *const Rope, index: usize) u8 {
        std.debug.assert(index < rope.len());
        return byteAtIn(rope.root, index);
    }

    pub const ChunkIterator = struct {
        stack: [128]*const Node = undefined,
        depth: usize = 0,

        pub fn next(it: *ChunkIterator) ?[]const u8 {
            while (it.depth > 0) {
                it.depth -= 1;
                const node = it.stack[it.depth];
                switch (node.*) {
                    .leaf => |leaf| return leaf.items,
                    .branch => |branch| {
                        it.stack[it.depth] = branch.right;
                        it.stack[it.depth + 1] = branch.left;
                        it.depth += 2;
                    },
                }
            }
            return null;
        }

        fn init(root: ?*const Node) ChunkIterator {
            var it: ChunkIterator = .{};
            if (root) |r| {
                it.stack[0] = r;
                it.depth = 1;
            }
            return it;
        }
    };

    pub fn chunks(rope: *const Rope) ChunkIterator {
        return .init(rope.root);
    }

    pub fn toOwnedSlice(rope: *const Rope, gpa: Allocator) Allocator.Error![]u8 {
        return copyText(gpa, rope.root);
    }

    pub fn format(rope: Rope, writer: *Io.Writer) Io.Writer.Error!void {
        return writeText(writer, rope.root);
    }

    pub fn snapshot(rope: *Rope) Snapshot {
        if (rope.root) |root| _ = root.retain();
        return .{ .root = rope.root };
    }

    pub fn release(rope: *Rope, snap: Snapshot) void {
        if (snap.root) |root| root.release(rope.memory());
    }

    pub fn restore(rope: *Rope, snap: Snapshot) void {
        if (snap.root) |root| _ = root.retain();
        if (rope.root) |root| root.release(rope.memory());
        rope.root = snap.root;
    }

    pub fn insert(rope: *Rope, index: usize, text: []const u8) Allocator.Error!void {
        std.debug.assert(index <= rope.len());
        if (text.len == 0) return;
        const mem = rope.memory();
        if (rope.root) |root| {
            if (try insertInPlace(mem.gpa, root, index, text)) return;
        }
        const middle = try build(mem, text);
        const root = rope.root orelse {
            rope.root = middle;
            return;
        };
        rope.root = null;
        const before, const after = split(mem, root, index) catch |err| {
            middle.release(mem);
            return err;
        };
        const head = join(mem, before, middle) catch |err| {
            if (after) |n| n.release(mem);
            return err;
        };
        rope.root = try join(mem, head, after);
    }

    pub fn delete(rope: *Rope, start: usize, count: usize) Allocator.Error!void {
        std.debug.assert(start + count <= rope.len());
        const mem = rope.memory();
        const root = rope.root.?;
        if (deleteInPlace(root, start, count)) return;
        rope.root = null;
        const before, const rest = try split(mem, root, start);
        const removed, const after = split(mem, rest.?, count) catch |err| {
            if (before) |n| n.release(mem);
            return err;
        };
        if (removed) |n| n.release(mem);
        rope.root = try join(mem, before, after);
    }

    pub fn append(rope: *Rope, text: []const u8) Allocator.Error!void {
        return rope.insert(rope.len(), text);
    }
};

fn checkNode(node: *const Node) !u32 {
    switch (node.*) {
        .leaf => |leaf| {
            try std.testing.expect(leaf.items.len > 0);
            try std.testing.expect(leaf.items.len <= max_leaf);
            return 0;
        },
        .branch => |branch| {
            const lh = try checkNode(branch.left);
            const rh = try checkNode(branch.right);
            try std.testing.expectEqual(branch.left.len() + branch.right.len(), branch.len);
            try std.testing.expectEqual(1 + @max(lh, rh), branch.height);
            try std.testing.expect(@max(lh, rh) - @min(lh, rh) <= 1);
            return branch.height;
        },
    }
}

test "a leaf knows its length" {
    const gpa = std.testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "hi");
    const node: Node = .{ .leaf = list };
    try std.testing.expectEqual(2, node.len());
    try std.testing.expectEqual(0, node.height());
}

test "build a small tree by hand" {
    const gpa = std.testing.allocator;
    var nodes: NodePool = .{};
    defer nodes.deinit(gpa);
    const mem: Mem = .{ .gpa = gpa, .nodes = &nodes };

    const a = try Node.createLeaf(mem, "Hello, ");
    const b = try Node.createLeaf(mem, "world");
    const root = try Node.createBranch(mem, a, b);
    try std.testing.expectEqual(12, root.len());
    try std.testing.expectEqual(1, root.height());
    try std.testing.expectEqual(3, nodes.live);

    root.release(mem);
    try std.testing.expectEqual(0, nodes.live);
}

test "build makes a balanced tree" {
    const gpa = std.testing.allocator;
    var nodes: NodePool = .{};
    defer nodes.deinit(gpa);
    const mem: Mem = .{ .gpa = gpa, .nodes = &nodes };

    const text = try gpa.alloc(u8, 10_000);
    defer gpa.free(text);
    @memset(text, 'a');
    const root = try build(mem, text);
    defer root.release(mem);
    try std.testing.expectEqual(10_000, root.len());
    try std.testing.expectEqual(4, try checkNode(root));
    try std.testing.expectEqual(31, nodes.live); // 16 leaves + 15 branches
}

test "empty rope" {
    var rope: Rope = .init(std.testing.allocator);
    defer rope.deinit();
    try std.testing.expectEqual(0, rope.len());
}

test "fromSlice" {
    var rope = try Rope.fromSlice(std.testing.allocator, "hello");
    defer rope.deinit();
    try std.testing.expectEqual(5, rope.len());
    try std.testing.expectEqual(0, rope.height());
}

test "byteAt" {
    const text = "The quick brown fox";
    var rope = try Rope.fromSlice(std.testing.allocator, text);
    defer rope.deinit();
    for (text, 0..) |c, i| try std.testing.expectEqual(c, rope.byteAt(i));
}

fn countNodes(node: *const Node) usize {
    return switch (node.*) {
        .leaf => 1,
        .branch => |branch| 1 + countNodes(branch.left) + countNodes(branch.right),
    };
}

fn checkRope(rope: *const Rope, expected: []const u8) !void {
    if (rope.root) |root| _ = try checkNode(root);
    const in_tree = if (rope.root) |root| countNodes(root) else 0;
    try std.testing.expectEqual(in_tree, rope.nodes.live); // no lost nodes
    try std.testing.expectEqual(expected.len, rope.len());
    const text = try rope.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "round trip through chunks" {
    const gpa = std.testing.allocator;
    const text = try gpa.alloc(u8, 10_000);
    defer gpa.free(text);
    for (text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var rope = try Rope.fromSlice(gpa, text);
    defer rope.deinit();
    try checkRope(&rope, text);
}

test "format with {f}" {
    var rope = try Rope.fromSlice(std.testing.allocator, "abc");
    defer rope.deinit();
    try std.testing.expectFmt("[abc]", "[{f}]", .{rope});
}

test "rebalance fixes a left-heavy tree" {
    var rope: Rope = .init(std.testing.allocator);
    defer rope.deinit();
    const mem = rope.memory();

    const ab = try Node.createBranch(mem, try Node.createLeaf(mem, "a"), try Node.createLeaf(mem, "b"));
    const abc = try Node.createBranch(mem, ab, try Node.createLeaf(mem, "c"));
    const abcd = try Node.createBranch(mem, abc, try Node.createLeaf(mem, "d"));
    try std.testing.expectEqual(3, abcd.height()); // left 2, right 0: not AVL
    rope.root = try rebalance(mem, abcd);
    try std.testing.expectEqual(2, rope.height());
    try checkRope(&rope, "abcd");
}

test "join trees of different heights" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 20_000);
    defer gpa.free(big);
    for (big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    var rope: Rope = .init(gpa);
    defer rope.deinit();
    const mem = rope.memory();
    const left = try build(mem, big);
    const right = try build(mem, "tail");
    rope.root = try join(mem, left, right);

    const expected = try std.mem.concat(gpa, u8, &.{ big, "tail" });
    defer gpa.free(expected);
    try checkRope(&rope, expected);
}

test "split at every position" {
    const gpa = std.testing.allocator;
    var text: [3000]u8 = undefined;
    for (&text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var i: usize = 0;
    while (i <= text.len) : (i += 97) {
        // Split twice: once to check the left half, once for the right half.
        for ([_]bool{ true, false }) |keep_left| {
            var rope = try Rope.fromSlice(gpa, &text);
            defer rope.deinit();
            const root = rope.root.?;
            rope.root = null;
            const a, const b = try split(rope.memory(), root, i);
            const kept = if (keep_left) a else b;
            const dropped = if (keep_left) b else a;
            if (dropped) |n| n.release(rope.memory());
            rope.root = kept;
            try checkRope(&rope, if (keep_left) text[0..i] else text[i..]);
        }
    }
}

test "insert" {
    var rope = try Rope.fromSlice(std.testing.allocator, "Hello world");
    defer rope.deinit();
    try rope.insert(5, ",");
    try checkRope(&rope, "Hello, world");
    try rope.append("!");
    try checkRope(&rope, "Hello, world!");
    try rope.insert(0, ">> ");
    try checkRope(&rope, ">> Hello, world!");
}

test "delete" {
    var rope = try Rope.fromSlice(std.testing.allocator, "Hello, world!");
    defer rope.deinit();
    try rope.delete(0, 7);
    try checkRope(&rope, "world!");
    try rope.delete(5, 1);
    try checkRope(&rope, "world");
    try rope.delete(0, 5);
    try checkRope(&rope, "");
}

test "random edits match an ArrayList" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    var rope: Rope = .init(gpa);
    defer rope.deinit();

    var buf: [3000]u8 = undefined;
    for (0..2000) |_| {
        const len = rope.len();
        if (len == 0 or random.boolean()) {
            const n = random.intRangeAtMost(usize, 1, buf.len);
            for (buf[0..n]) |*c| c.* = random.intRangeAtMost(u8, 'a', 'z');
            const at = random.intRangeAtMost(usize, 0, len);
            try rope.insert(at, buf[0..n]);
            try model.insertSlice(gpa, at, buf[0..n]);
        } else {
            const start = random.uintLessThan(usize, len);
            const count = random.intRangeAtMost(usize, 1, @min(len - start, 2000));
            try rope.delete(start, count);
            model.replaceRangeAssumeCapacity(start, count, &.{});
        }
        if (rope.root) |root| _ = try checkNode(root);
    }
    try checkRope(&rope, model.items);
}

fn editsUnderMemoryPressure(gpa: Allocator) !void {
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var rope = try Rope.fromSlice(gpa, &big);
    defer rope.deinit();
    try rope.insert(2500, &big);
    try rope.delete(100, 4000);
    try rope.insert(0, "x");
}

test "no leaks when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editsUnderMemoryPressure, .{});
}

test "retain and release" {
    var rope: Rope = .init(std.testing.allocator);
    defer rope.deinit();
    const mem = rope.memory();

    const leaf = try Node.createLeaf(mem, "abc");
    try std.testing.expect(!leaf.isShared());
    _ = leaf.retain();
    try std.testing.expect(leaf.isShared());
    leaf.release(mem); // one owner left: the node stays
    try std.testing.expect(!leaf.isShared());
    try std.testing.expectEqual(1, rope.nodes.live);
    leaf.release(mem); // last owner: the node is freed
    try std.testing.expectEqual(0, rope.nodes.live);
}

/// Check the invariants and the text of a tree that may share nodes.
fn checkText(root: ?*const Node, expected: []const u8) !void {
    if (root) |r| _ = try checkNode(r);
    const text = try copyText(std.testing.allocator, root);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

test "a snapshot shares the text of the rope" {
    const xs: [3000]u8 = @splat('x');
    var rope = try Rope.fromSlice(std.testing.allocator, &xs);
    defer rope.deinit();
    const nodes_before = rope.nodes.live;

    const snap = rope.snapshot();
    defer rope.release(snap);
    try std.testing.expectEqual(nodes_before, rope.nodes.live); // nothing was copied
    try std.testing.expect(rope.root.?.isShared());
    try std.testing.expectEqual(3000, snap.len());
    try std.testing.expectEqual('x', snap.byteAt(1234));
    try checkText(snap.root, &xs);
}

test "own copies only a shared node" {
    const xs: [3000]u8 = @splat('x');
    var rope = try Rope.fromSlice(std.testing.allocator, &xs);
    defer rope.deinit();
    const mem = rope.memory();
    const root = rope.root.?;

    try std.testing.expectEqual(root, try root.own(mem)); // not shared: same node

    const snap = rope.snapshot();
    defer rope.release(snap);
    const copy = try root.own(mem); // shared: a new branch, same children
    rope.root = copy;
    try std.testing.expect(copy != root);
    try std.testing.expect(copy.branch.left == root.branch.left);
    try std.testing.expect(copy.branch.left.isShared());
    try checkText(rope.root, &xs);
    try checkText(snap.root, &xs);
}

test "split leaves a shared tree unchanged" {
    var text: [3000]u8 = undefined;
    for (&text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var rope = try Rope.fromSlice(std.testing.allocator, &text);
    defer rope.deinit();
    const mem = rope.memory();
    var i: usize = 0;
    while (i <= text.len) : (i += 97) {
        // Split a second reference to the tree. The rope keeps the first.
        const a, const b = try split(mem, rope.root.?.retain(), i);
        try checkText(a, text[0..i]);
        try checkText(b, text[i..]);
        if (a) |n| n.release(mem);
        if (b) |n| n.release(mem);
        try checkRope(&rope, &text); // unchanged, and no node lost
    }
}

test "rebalance does not change shared children" {
    var rope: Rope = .init(std.testing.allocator);
    defer rope.deinit();
    const mem = rope.memory();

    // The left child leans right, so rebalance needs a double rotation.
    const bc = try Node.createBranch(mem, try Node.createLeaf(mem, "b"), try Node.createLeaf(mem, "c"));
    const abc = try Node.createBranch(mem, try Node.createLeaf(mem, "a"), bc);
    const other = abc.retain(); // a second owner, like a snapshot
    defer other.release(mem);
    const abcd = try Node.createBranch(mem, abc, try Node.createLeaf(mem, "d"));
    rope.root = try rebalance(mem, abcd);
    try checkText(rope.root, "abcd");
    try std.testing.expectEqual(2, rope.height());
    try checkText(other, "abc"); // the shared subtree is unchanged
}

test "a snapshot keeps its text while the rope changes" {
    var rope = try Rope.fromSlice(std.testing.allocator, "Hello world");
    defer rope.deinit();
    const snap = rope.snapshot();
    defer rope.release(snap);

    try rope.insert(5, ",");
    try rope.append("!");
    try rope.delete(0, 1);
    try checkText(rope.root, "ello, world!");
    try checkText(snap.root, "Hello world");
    try std.testing.expectFmt("Hello world", "{f}", .{snap});
}

test "random edits, snapshots and undo match copies of the text" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);
    var rope: Rope = .init(gpa);
    defer rope.deinit();

    var snaps: [20]Snapshot = undefined;
    var copies: [20][]u8 = undefined;
    var count: usize = 0;
    defer for (snaps[0..count], copies[0..count]) |snap, copy| {
        rope.release(snap);
        gpa.free(copy);
    };

    var buf: [3000]u8 = undefined;
    for (0..2000) |step| {
        const len = rope.len();
        if (count > 0 and random.uintLessThan(u32, 50) == 0) {
            const k = random.uintLessThan(usize, count);
            rope.restore(snaps[k]);
            model.clearRetainingCapacity();
            try model.appendSlice(gpa, copies[k]);
        } else if (len == 0 or random.boolean()) {
            const n = random.intRangeAtMost(usize, 1, @as(usize, if (random.boolean()) 8 else buf.len));
            for (buf[0..n]) |*c| c.* = random.intRangeAtMost(u8, 'a', 'z');
            const at = random.intRangeAtMost(usize, 0, len);
            try rope.insert(at, buf[0..n]);
            try model.insertSlice(gpa, at, buf[0..n]);
        } else {
            const start = random.uintLessThan(usize, len);
            const n = random.intRangeAtMost(usize, 1, @min(len - start, @as(usize, if (random.boolean()) 8 else 2000)));
            try rope.delete(start, n);
            model.replaceRangeAssumeCapacity(start, n, &.{});
        }
        if (rope.root) |root| _ = try checkNode(root);
        if (step % 100 == 0) {
            copies[count] = try gpa.dupe(u8, model.items);
            snaps[count] = rope.snapshot();
            count += 1;
        }
    }
    for (snaps[0..count], copies[0..count]) |snap, copy| try checkText(snap.root, copy);
    try checkText(rope.root, model.items);
}

test "restore is undo" {
    var rope = try Rope.fromSlice(std.testing.allocator, "one");
    defer rope.deinit();
    const before = rope.snapshot();
    defer rope.release(before);

    try rope.append(" two");
    rope.restore(before);
    try checkText(rope.root, "one");
    try rope.append(" three"); // editing after undo must not change `before`
    try checkText(rope.root, "one three");
    try checkText(before.root, "one");
}

fn readMany(snap: Snapshot, expected: []const u8, ok: *bool) void {
    ok.* = true;
    for (0..20) |_| {
        var pos: usize = 0;
        var it = snap.chunks();
        while (it.next()) |chunk| : (pos += chunk.len) {
            if (pos + chunk.len > expected.len or
                !std.mem.eql(u8, chunk, expected[pos..][0..chunk.len])) ok.* = false;
        }
        if (pos != expected.len) ok.* = false;
    }
}

test "other threads read snapshots while the rope changes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();

    var text: [64 * 1024]u8 = undefined;
    for (&text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var rope = try Rope.fromSlice(gpa, &text);
    defer rope.deinit();

    var threads: [4]std.Thread = undefined;
    var snaps: [4]Snapshot = undefined;
    var copies: [4][]u8 = undefined;
    var ok: [4]bool = undefined;
    for (0..4) |t| {
        snaps[t] = rope.snapshot();
        copies[t] = try rope.toOwnedSlice(gpa);
        threads[t] = try std.Thread.spawn(.{}, readMany, .{ snaps[t], copies[t], &ok[t] });
        // Edit while the reader runs.
        for (0..300) |_| {
            if (random.boolean()) {
                try rope.insert(random.uintAtMost(usize, rope.len()), "edit");
            } else {
                try rope.delete(random.uintLessThan(usize, rope.len() - 4), 4);
            }
        }
    }
    for (threads, snaps, copies, ok) |thread, snap, copy, good| {
        thread.join(); // after join, the reader is done with the snapshot
        rope.release(snap);
        gpa.free(copy);
        try std.testing.expect(good);
    }
}

fn editsWithSnapshots(gpa: Allocator) !void {
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    var rope = try Rope.fromSlice(gpa, &big);
    defer rope.deinit();
    const snap = rope.snapshot();
    defer rope.release(snap);
    try rope.insert(2500, &big);
    try rope.delete(100, 4000);
    try rope.insert(0, "x");
    rope.restore(snap);
    try rope.delete(10, 10);
}

test "no leaks when allocation fails with snapshots" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editsWithSnapshots, .{});
}
