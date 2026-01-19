const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const simgui = sokol.imgui;
const ig = @import("cimgui");

const math = @import("math");
const shader = @import("shader");
const bvh = @import("../lib/bvh.zig");
const brush = @import("../lib/brush.zig");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Config = struct {
    // Rendering settings
    fov: f32 = 90.0,
    aspect_ratio: f32 = 1.33,
    near_plane: f32 = 0.1,
    far_plane: f32 = 500.0,
    
    // Clear color
    clear_color: struct {
        r: f32 = 0.15,
        g: f32 = 0.15,
        b: f32 = 0.18,
        a: f32 = 1.0,
    } = .{},
    
    // Crosshair
    crosshair_size: f32 = 8.0,
    crosshair_color: u32 = 0xFF00FF00,
    
    // Default brush color
    brush_color: [4]f32 = .{ 0.4, 0.4, 0.4, 1.0 },
    
    // Mesh generation
    vertex_epsilon: f32 = 0.001,
    vertex_distance_threshold: f32 = 0.01,
    normal_epsilon: f32 = 0.001,
};

pub fn Renderer(comptime config: Config) type {
   return struct {
        const Self = @This();
        
        // Vertex format for rendering
        const Vertex = extern struct { pos: [3]f32, col: [4]f32 };
        
        // Mesh builder for converting brushes to renderable geometry
        const MeshBuilder = struct {
            vertices: std.ArrayListUnmanaged(Vertex) = .{},
            indices: std.ArrayListUnmanaged(u16) = .{},
            allocator: std.mem.Allocator,
            
            fn init(allocator: std.mem.Allocator) MeshBuilder { 
                return .{ .allocator = allocator }; 
            }
            
            fn deinit(self: *MeshBuilder) void { 
                self.vertices.deinit(self.allocator); 
                self.indices.deinit(self.allocator); 
            }
            
            fn addBrush(self: *MeshBuilder, b: brush.Brush, color: [4]f32) !void {
                var hull_vertices = std.ArrayListUnmanaged(Vec3){};
                defer hull_vertices.deinit(self.allocator);
                
                for (0..b.planes.len()) |i| {
                    for (i + 1..b.planes.len()) |j| {
                        for (j + 1..b.planes.len()) |k| {
                            // intersect three planes
                            const intersection = blk: {
                                const n1 = b.planes.normals[i];
                                const n2 = b.planes.normals[j];
                                const n3 = b.planes.normals[k];
                                const d1 = b.planes.distances[i];
                                const d2 = b.planes.distances[j];
                                const d3 = b.planes.distances[k];
                                
                                const det = Vec3.dot(n1, Vec3.cross(n2, n3));
                                if (@abs(det) < config.vertex_epsilon) break :blk null;
                                
                                const c1 = Vec3.cross(n2, n3);
                                const c2 = Vec3.cross(n3, n1);
                                const c3 = Vec3.cross(n1, n2);
                                
                                break :blk Vec3.scale(Vec3.add(Vec3.add(Vec3.scale(c1, -d1), Vec3.scale(c2, -d2)), Vec3.scale(c3, -d3)), 1.0 / det);
                            };
                            
                            if (intersection) |vertex| {
                                // check if vertex is inside brush
                                const inside_brush = blk: {
                                    for (0..b.planes.len()) |plane_idx| {
                                        if (b.planes.distanceToPoint(plane_idx, vertex) > config.vertex_epsilon) break :blk false;
                                    }
                                    break :blk true;
                                };
                                
                                // check if vertex is duplicate
                                const is_duplicate = blk: {
                                    for (hull_vertices.items) |existing| if (Vec3.dist(vertex, existing) < config.vertex_distance_threshold) break :blk true;
                                    break :blk false;
                                };
                                
                                if (inside_brush and !is_duplicate) {
                                    try hull_vertices.append(self.allocator, vertex);
                                }
                            }
                        }
                    }
                }
                
                if (hull_vertices.items.len < 4) return;
                
                // Generate convex hull using gift wrapping
                const hull_faces = try self.generateConvexHullFaces(hull_vertices.items);
                defer self.allocator.free(hull_faces);
                
                const base = @as(u16, @intCast(self.vertices.items.len));
                
                for (hull_vertices.items) |v| {
                    try self.vertices.append(self.allocator, .{ .pos = .{ v.data[0], v.data[1], v.data[2] }, .col = color });
                }
                
                for (hull_faces) |face| {
                    try self.indices.append(self.allocator, base + face[0]);
                    try self.indices.append(self.allocator, base + face[1]);
                    try self.indices.append(self.allocator, base + face[2]);
                }
            }
            
            fn generateConvexHullFaces(self: *MeshBuilder, vertices: []Vec3) ![][3]u16 {
                if (vertices.len < 4) return &[_][3]u16{};
                
                var faces = std.ArrayListUnmanaged([3]u16){};
                
                // Simple approach: test all triangles, keep those that are hull faces
                for (0..vertices.len) |i| {
                    for (i + 1..vertices.len) |j| {
                        for (j + 1..vertices.len) |k| {
                            const v0 = vertices[i];
                            const v1 = vertices[j]; 
                            const v2 = vertices[k];
                            
                            const edge1 = Vec3.sub(v1, v0);
                            const edge2 = Vec3.sub(v2, v0);
                            const normal = Vec3.cross(edge1, edge2);
                            
                            if (Vec3.length(normal) < config.normal_epsilon) continue;
                            
                            // Check if all other vertices are on one side of this triangle
                            var is_hull_face = true;
                            var side_sign: ?f32 = null;
                            
                            for (vertices, 0..) |test_vertex, idx| {
                                if (idx == i or idx == j or idx == k) continue;
                                
                                const dot = Vec3.dot(normal, Vec3.sub(test_vertex, v0));
                                if (@abs(dot) > config.vertex_epsilon) {
                                    if (side_sign == null) {
                                        side_sign = dot;
                                    } else if (side_sign.? * dot < 0) {
                                        is_hull_face = false;
                                        break;
                                    }
                                }
                            }
                            
                            if (is_hull_face) {
                                const face: [3]u16 = if ((side_sign orelse 1) > 0) 
                                    .{ @intCast(i), @intCast(k), @intCast(j) }
                                else 
                                    .{ @intCast(i), @intCast(j), @intCast(k) };
                                try faces.append(self.allocator, face);
                            }
                        }
                    }
                }
                
                return try faces.toOwnedSlice(self.allocator);
            }
        };
        
        allocator: std.mem.Allocator,
        
        // Rendering
        pipeline: sg.Pipeline = undefined,
        bindings: sg.Bindings = undefined,
        pass_action: sg.PassAction = undefined,
        vertex_count: u32 = 0,
        
        // World mesh building
        mesh_builder: MeshBuilder,
        
        pub fn init(allocator: std.mem.Allocator) Self {
            var renderer = Self{
                .allocator = allocator,
                .mesh_builder = MeshBuilder.init(allocator),
            };
            
            renderer.initializePipeline();
            return renderer;
        }
        
        pub fn deinit(self: *Self) void {
            self.mesh_builder.deinit();
        }
        
        fn initializePipeline(self: *Self) void {
            var layout = sg.VertexLayoutState{};
            layout.attrs[0].format = .FLOAT3;
            layout.attrs[1].format = .FLOAT4;
            
            self.pipeline = sg.makePipeline(.{ 
                .shader = sg.makeShader(shader.shaderShaderDesc(sg.queryBackend())), 
                .layout = layout, 
                .index_type = .UINT16, 
                .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true }, 
                .cull_mode = .NONE 
            });
            
            self.pass_action = .{ 
                .colors = .{ 
                    .{ .load_action = .CLEAR, .clear_value = .{ 
                        .r = config.clear_color.r, 
                        .g = config.clear_color.g, 
                        .b = config.clear_color.b, 
                        .a = config.clear_color.a 
                    } }, 
                    .{}, .{}, .{}, .{}, .{}, .{}, .{} 
                } 
            };
        }
        
        pub fn buildWorldMesh(self: *Self, brushes: []const brush.Brush) !void {
            // Build visual representation using brushes for rendering
            for (brushes) |b| {
                self.mesh_builder.addBrush(b, config.brush_color) catch continue;
            }
            
            try self.buildBuffers();
        }
        
        pub fn buildBuffers(self: *Self) !void {
            if (self.bindings.vertex_buffers[0].id != 0) sg.destroyBuffer(self.bindings.vertex_buffers[0]);
            if (self.bindings.index_buffer.id != 0) sg.destroyBuffer(self.bindings.index_buffer);
            
            if (self.mesh_builder.vertices.items.len > 0) {
                self.bindings.vertex_buffers[0] = sg.makeBuffer(.{ 
                    .data = .{ 
                        .ptr = self.mesh_builder.vertices.items.ptr, 
                        .size = self.mesh_builder.vertices.items.len * @sizeOf(Vertex) 
                    } 
                });
                self.bindings.index_buffer = sg.makeBuffer(.{ 
                    .usage = .{ .index_buffer = true }, 
                    .data = .{ 
                        .ptr = self.mesh_builder.indices.items.ptr, 
                        .size = self.mesh_builder.indices.items.len * @sizeOf(u16) 
                    } 
                });
            }
            
            // Return error if index count is too large for u32
            self.vertex_count = std.math.cast(u32, self.mesh_builder.indices.items.len) orelse return error.TooManyIndices;
        }
        
        pub fn render(self: *const Self, view: Mat4) void {
            const mvp = Mat4.mul(
                math.perspective(
                    config.fov, 
                    config.aspect_ratio, 
                    config.near_plane, 
                    config.far_plane
                ), 
                view
            );
            
            sg.beginPass(.{ .action = self.pass_action, .swapchain = sokol.glue.swapchain() });
            sg.applyPipeline(self.pipeline);
            sg.applyBindings(self.bindings);
            sg.applyUniforms(0, sg.asRange(&mvp));
            sg.draw(0, self.vertex_count, 1);
        }
        
        pub fn renderCrosshair(self: *const Self) void {
            _ = self;
            const cx = @as(f32, @floatFromInt(sokol.app.width())) * 0.5;
            const cy = @as(f32, @floatFromInt(sokol.app.height())) * 0.5;
            const crosshair_size = config.crosshair_size;
            const dl = ig.igGetBackgroundDrawList();
            
            ig.ImDrawList_AddLine(dl, 
                .{ .x = cx - crosshair_size, .y = cy }, 
                .{ .x = cx + crosshair_size, .y = cy }, 
                config.crosshair_color
            );
            ig.ImDrawList_AddLine(dl, 
                .{ .x = cx, .y = cy - crosshair_size }, 
                .{ .x = cx, .y = cy + crosshair_size }, 
                config.crosshair_color
            );
        }
    };
}