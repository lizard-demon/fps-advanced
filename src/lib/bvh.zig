const std = @import("std");
const math = @import("math");
const Vec3 = math.Vec3;
const AABB = math.AABB;

// Configuration for BVH construction
const Config = struct {
    traversal_cost: f32 = 0.3,
    max_leaf_size: u32 = 4,
    split_candidates: u32 = 8,
    max_stack_depth: u32 = 64,
    layout_queue_initial_size: u32 = 512,
    min_stack_size: u32 = 32,
    stack_size_multiplier: u32 = 2,
    stack_size_padding: u32 = 8,
};

// BVH Node - packed for cache efficiency
const NodeType = enum(u2) { x_axis = 0, y_axis = 1, z_axis = 2, leaf = 3 };

const Node = struct {
    first: u32,
    count: u30,
    node_type: NodeType,
    bounds: AABB,
};

// Generic BVH implementation
pub fn BVH(comptime T: type) type {
    return struct {
        const Self = @This();
        const config = Config{};
        
        items: []const T,
        nodes: std.MultiArrayList(Node) = .{},
        indices: std.ArrayListUnmanaged(u32) = .{}, 
        allocator: std.mem.Allocator,
        
        pub fn init(items: []const T, allocator: std.mem.Allocator, bounds_fn: fn(T) AABB) !Self {
            if (items.len == 0) return .{ .items = items, .allocator = allocator };
            
            var indices = std.ArrayListUnmanaged(u32){};
            try indices.ensureTotalCapacity(allocator, items.len);
            for (0..items.len) |i| indices.appendAssumeCapacity(@intCast(i));
            
            var bvh = Self{ .items = items, .indices = indices, .allocator = allocator };
            _ = try bvh.build(bounds_fn);
            return bvh;
        }
        
        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.indices.deinit(self.allocator);
        }
        
        pub fn query(self: *const Self, query_bounds: AABB, test_fn: fn(T) bool) bool {
            if (self.nodes.len == 0) {
                for (self.items) |item| if (test_fn(item)) return true;
                return false;
            }
            
            var stack: [config.max_stack_depth]u32 = undefined;
            var stack_ptr: u32 = 1;
            stack[0] = 0;
            
            while (stack_ptr > 0) {
                stack_ptr -= 1;
                const node_idx = stack[stack_ptr];
                if (node_idx >= self.nodes.len) continue;
                
                const node_bounds = self.nodes.get(node_idx).bounds;
                const node_type = self.nodes.get(node_idx).node_type;
                if (!node_bounds.intersects(query_bounds)) continue;
                
                if (node_type == .leaf) {
                    const first = self.nodes.get(node_idx).first;
                    const count = self.nodes.get(node_idx).count;
                    const end_idx = @min(first + count, self.indices.items.len);
                    for (first..end_idx) |i| {
                        if (test_fn(self.items[self.indices.items[i]])) return true;
                    }
                } else {
                    const left_child = self.nodes.get(node_idx).first;
                    const right_child = left_child + 1;
                    
                    if (right_child < self.nodes.len and stack_ptr < stack.len) {
                        stack[stack_ptr] = right_child;
                        stack_ptr += 1;
                    }
                    if (left_child < self.nodes.len and stack_ptr < stack.len) {
                        stack[stack_ptr] = left_child;
                        stack_ptr += 1;
                    }
                }
            }
            return false;
        }
        
        fn build(self: *Self, bounds_fn: fn(T) AABB) !void {
            var nodes = std.MultiArrayList(Node){};
            defer nodes.deinit(self.allocator);
            _ = try self.buildRecursive(0, @intCast(self.items.len), &nodes, bounds_fn);
            try self.flatten(nodes.slice());
        }
        
        fn buildRecursive(self: *Self, start: u32, count: u32, nodes: *std.MultiArrayList(Node), bounds_fn: fn(T) AABB) !u32 {
            const node_idx = @as(u32, @intCast(nodes.len));
            var bounds = bounds_fn(self.items[self.indices.items[start]]);
            for (start + 1..start + count) |i| {
                bounds = bounds.union_with(bounds_fn(self.items[self.indices.items[i]]));
            }
            
            try nodes.append(self.allocator, .{
                .first = start, 
                .count = @intCast(count),
                .node_type = .leaf,
                .bounds = bounds,
            });
            
            if (count <= config.max_leaf_size) return node_idx;
            
            const best_split = self.split(start, count, bounds, bounds_fn);
            if (best_split.cost >= @as(f32, @floatFromInt(count))) return node_idx;
            
            const split_idx = self.partition(start, count, best_split.axis, best_split.pos, bounds_fn);
            const left_count = split_idx - start;
            const right_count = (start + count) - split_idx;
            if (left_count == 0 or right_count == 0) return node_idx;
            
            const left_child = try self.buildRecursive(start, left_count, nodes, bounds_fn);
            _ = try self.buildRecursive(split_idx, right_count, nodes, bounds_fn);
            
            nodes.set(node_idx, .{
                .first = left_child,
                .count = 0,
                .node_type = @enumFromInt(best_split.axis),
                .bounds = bounds,
            });
            return node_idx;
        }
        
        const Split = struct { axis: u32, pos: f32, cost: f32 };
        
        fn split(self: *Self, start: u32, count: u32, bounds: AABB, bounds_fn: fn(T) AABB) Split {
            var best = Split{ .axis = 0, .pos = 0, .cost = std.math.floatMax(f32) };
            const parent_area = bounds.surface_area();
            if (parent_area <= 0) return best;
            
            for (0..3) |axis| {
                const axis_min = bounds.min.data[axis];
                const axis_max = bounds.max.data[axis];
                const axis_range = axis_max - axis_min;
                if (axis_range <= std.math.floatEpsAt(f32, axis_range)) continue;
                
                const step = axis_range / @as(f32, @floatFromInt(config.split_candidates));
                for (0..config.split_candidates) |candidate| {
                    const split_pos = axis_min + step * (@as(f32, @floatFromInt(candidate)) + 0.5);
                    
                    var left_bounds: ?AABB = null;
                    var right_bounds: ?AABB = null;
                    var left_count: u32 = 0;
                    var right_count: u32 = 0;
                    
                    for (start..start + count) |j| {
                        const prim_bounds = bounds_fn(self.items[self.indices.items[j]]);
                        const centroid = (prim_bounds.min.data[axis] + prim_bounds.max.data[axis]) * 0.5;
                        
                        if (centroid < split_pos) {
                            left_count += 1;
                            left_bounds = if (left_bounds) |lb| lb.union_with(prim_bounds) else prim_bounds;
                        } else {
                            right_count += 1;
                            right_bounds = if (right_bounds) |rb| rb.union_with(prim_bounds) else prim_bounds;
                        }
                    }
                    
                    if (left_count == 0 or right_count == 0) continue;
                    
                    const left_area = if (left_bounds) |lb| lb.surface_area() else 0;
                    const right_area = if (right_bounds) |rb| rb.surface_area() else 0;
                    const cost = config.traversal_cost + 
                        (left_area / parent_area) * @as(f32, @floatFromInt(left_count)) + 
                        (right_area / parent_area) * @as(f32, @floatFromInt(right_count));
                    
                    if (cost < best.cost) {
                        best = .{ .axis = @intCast(axis), .pos = split_pos, .cost = cost };
                    }
                }
            }
            return best;
        }
        
        fn partition(self: *Self, start: u32, count: u32, axis: u32, split_pos: f32, bounds_fn: fn(T) AABB) u32 {
            var left = start;
            var right = start + count - 1;
            while (left <= right) {
                const prim_bounds = bounds_fn(self.items[self.indices.items[left]]);
                const centroid = (prim_bounds.min.data[axis] + prim_bounds.max.data[axis]) * 0.5;
                if (centroid < split_pos) {
                    left += 1;
                } else {
                    const temp = self.indices.items[left];
                    self.indices.items[left] = self.indices.items[right];
                    self.indices.items[right] = temp;
                    if (right == 0) break;
                    right -= 1;
                }
            }
            return left;
        }
        
        fn flatten(self: *Self, tree_nodes: std.MultiArrayList(Node).Slice) !void {
            if (tree_nodes.len == 0) return;
            
            try self.nodes.ensureTotalCapacity(self.allocator, tree_nodes.len);
            var queue = std.ArrayListUnmanaged(u32){};
            defer queue.deinit(self.allocator);
            
            try queue.ensureTotalCapacity(self.allocator, @max(config.layout_queue_initial_size, tree_nodes.len));
            queue.appendAssumeCapacity(0);
            
            var queue_head: u32 = 0;
            var write_idx: u32 = 0;
            
            while (queue_head < queue.items.len and write_idx < tree_nodes.len) {
                const tree_idx = queue.items[queue_head];
                queue_head += 1;
                
                if (tree_idx >= tree_nodes.len) continue;
                const tree_node = tree_nodes.get(tree_idx);
                self.nodes.appendAssumeCapacity(tree_node);
                
                if (tree_node.node_type != .leaf) {
                    const left_tree_idx = tree_node.first;
                    const right_tree_idx = left_tree_idx + 1;
                    
                    const left_bf_idx = write_idx + @as(u32, @intCast(queue.items.len - queue_head)) + 1;
                    self.nodes.set(write_idx, .{
                        .first = left_bf_idx,
                        .count = tree_node.count,
                        .node_type = tree_node.node_type,
                        .bounds = tree_node.bounds,
                    });
                    
                    if (left_tree_idx < tree_nodes.len) {
                        try queue.append(self.allocator, left_tree_idx);
                    }
                    if (right_tree_idx < tree_nodes.len) {
                        try queue.append(self.allocator, right_tree_idx);
                    }
                }
                write_idx += 1;
            }
        }
    };
}
