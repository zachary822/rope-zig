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

    fn destroy(node: *Node, mem: Mem) void {
        switch (node.*) {
            .leaf => |*leaf| leaf.deinit(mem.gpa),
            .branch => |branch| {
                branch.left.destroy(mem);
                branch.right.destroy(mem);
            },
        }
        mem.nodes.destroy(node);
    }
};

const NodePool = struct {
    pool: std.heap.MemoryPool(Node) = .empty,
    live: usize = 0,

    fn create(nodes: *NodePool, gpa: Allocator) Allocator.Error!*Node {
        const node = try nodes.pool.create(gpa);
        nodes.live += 1;
        return node;
    }

    fn destroy(nodes: *NodePool, node: *Node) void {
        nodes.pool.destroy(node);
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
    errdefer left.destroy(mem);
    const right = try build(mem, text[mid..]);
    errdefer right.destroy(mem);
    return Node.createBranch(mem, left, right);
}

fn rotateLeft(node: *Node) *Node {
    const pivot = node.branch.right;
    node.branch.right = pivot.branch.left;
    node.update();
    pivot.branch.left = node;
    pivot.update();
    return pivot;
}

fn rotateRight(node: *Node) *Node {
    const pivot = node.branch.left;
    node.branch.left = pivot.branch.right;
    node.update();
    pivot.branch.right = node;
    pivot.update();
    return pivot;
}

fn rebalance(node: *Node) *Node {
    node.update();
    const left = node.branch.left;
    const right = node.branch.right;
    if (left.height() > right.height() + 1) {
        if (left.branch.left.height() < left.branch.right.height()) {
            node.branch.left = rotateLeft(left);
        }
        return rotateRight(node);
    }
    if (right.height() > left.height() + 1) {
        if (right.branch.right.height() < right.branch.left.height()) {
            node.branch.right = rotateRight(right);
        }
        return rotateLeft(node);
    }
    return node;
}

fn joinNodes(mem: Mem, left: *Node, right: *Node) Allocator.Error!*Node {
    if (left.* == .leaf and right.* == .leaf and left.len() + right.len() <= max_leaf) {
        try left.leaf.appendSlice(mem.gpa, right.leaf.items);
        right.destroy(mem);
        return left;
    }
    if (left.height() > right.height() + 1) {
        left.branch.right = try joinNodes(mem, left.branch.right, right);
        return rebalance(left);
    }
    if (right.height() > left.height() + 1) {
        right.branch.left = try joinNodes(mem, left, right.branch.left);
        return rebalance(right);
    }
    return Node.createBranch(mem, left, right);
}

fn join(mem: Mem, left: ?*Node, right: ?*Node) Allocator.Error!?*Node {
    const l = left orelse return right;
    const r = right orelse return l;
    return joinNodes(mem, l, r) catch |err| {
        l.destroy(mem);
        r.destroy(mem);
        return err;
    };
}

fn split(mem: Mem, node: *Node, index: usize) Allocator.Error!struct { ?*Node, ?*Node } {
    switch (node.*) {
        .leaf => |*leaf| {
            if (index == 0) return .{ null, node };
            if (index == leaf.items.len) return .{ node, null };
            const right = Node.createLeaf(mem, leaf.items[index..]) catch |err| {
                node.destroy(mem);
                return err;
            };
            leaf.shrinkRetainingCapacity(index);
            return .{ node, right };
        },
        .branch => |branch| {
            const left = branch.left;
            const right = branch.right;
            mem.nodes.destroy(node);
            const weight = left.len();
            if (index < weight) {
                const a, const b = split(mem, left, index) catch |err| {
                    right.destroy(mem);
                    return err;
                };
                const rest = join(mem, b, right) catch |err| {
                    if (a) |n| n.destroy(mem);
                    return err;
                };
                return .{ a, rest };
            }
            if (index > weight) {
                const a, const b = split(mem, right, index - weight) catch |err| {
                    left.destroy(mem);
                    return err;
                };
                const first = join(mem, left, a) catch |err| {
                    if (b) |n| n.destroy(mem);
                    return err;
                };
                return .{ first, b };
            }

            return .{ left, right };
        },
    }
}

fn insertInPlace(gpa: Allocator, node: *Node, index: usize, text: []const u8) Allocator.Error!bool {
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
        if (rope.root) |root| root.destroy(rope.memory());
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
        var node = rope.root.?;
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
    };

    pub fn chunks(rope: *const Rope) ChunkIterator {
        var it: ChunkIterator = .{};

        if (rope.root) |root| {
            it.stack[0] = root;
            it.depth = 1;
        }
        return it;
    }

    pub fn toOwnedSlice(rope: *const Rope, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, rope.len());
        var pos: usize = 0;
        var it = rope.chunks();
        while (it.next()) |chunk| {
            @memcpy(out[pos..][0..chunk.len], chunk);
            pos += chunk.len;
        }
        return out;
    }

    pub fn format(rope: Rope, writer: *Io.Writer) Io.Writer.Error!void {
        var it = rope.chunks();
        while (it.next()) |chunk| try writer.writeAll(chunk);
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
            middle.destroy(mem);
            return err;
        };
        const head = join(mem, before, middle) catch |err| {
            if (after) |n| n.destroy(mem);
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
            if (before) |n| n.destroy(mem);
            return err;
        };
        if (removed) |n| n.destroy(mem);
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

    root.destroy(mem);
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
    defer root.destroy(mem);
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
    rope.root = rebalance(abcd);
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
            if (dropped) |n| n.destroy(rope.memory());
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
