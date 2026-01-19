const std = @import("std");
const math = @import("math");
const brush = @import("brush.zig");
const physics_mod = @import("../resources/physics.zig");

const Vec3 = math.Vec3;
const AABB = math.AABB;
const World = physics_mod.World;

pub const MapError = error{
    InvalidMapFormat,
    UnsupportedBrushType,
    TooManyBrushes,
    TooManyPlanes,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.json.ParseError(std.json.Scanner);

pub const BrushJson = struct {
    type: []const u8,
    position: [3]f32,
    size: ?[3]f32 = null,
    width: ?f32 = null,
    height: ?f32 = null,
    angle: ?f32 = null,
};

pub const MapJson = struct {
    name: []const u8,
    spawn_position: [3]f32,
    brushes: []BrushJson,
};

pub const BrushData = union(enum) {
    box: struct {
        position: [3]f32,
        size: [3]f32,
    },
    slope: struct {
        position: [3]f32,
        width: f32,
        height: f32,
        angle: f32,
    },
};

pub const MapData = struct {
    name: []const u8,
    spawn_position: [3]f32,
    brushes: []BrushData,
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    data: MapData,
    world: World,
    brushes: []brush.Brush,
    plane_normals: []Vec3,
    plane_distances: []f32,
    
    const MAX_BRUSHES = 32;
    const MAX_PLANES = 256;
    
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Map {
        // Read file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const contents = try allocator.alloc(u8, file_size);
        defer allocator.free(contents);
        _ = try file.readAll(contents);
        
        // Parse JSON
        const parsed = try std.json.parseFromSlice(MapJson, allocator, contents, .{});
        defer parsed.deinit();
        
        // Convert JSON format to internal format
        const brush_data = try allocator.alloc(BrushData, parsed.value.brushes.len);
        defer allocator.free(brush_data);
        
        for (parsed.value.brushes, 0..) |json_brush, i| {
            if (std.mem.eql(u8, json_brush.type, "box")) {
                if (json_brush.size == null) return MapError.InvalidMapFormat;
                brush_data[i] = .{ .box = .{
                    .position = json_brush.position,
                    .size = json_brush.size.?,
                }};
            } else if (std.mem.eql(u8, json_brush.type, "slope")) {
                if (json_brush.width == null or json_brush.height == null or json_brush.angle == null) {
                    return MapError.InvalidMapFormat;
                }
                brush_data[i] = .{ .slope = .{
                    .position = json_brush.position,
                    .width = json_brush.width.?,
                    .height = json_brush.height.?,
                    .angle = json_brush.angle.?,
                }};
            } else {
                return MapError.UnsupportedBrushType;
            }
        }
        
        const map_data = MapData{
            .name = parsed.value.name,
            .spawn_position = parsed.value.spawn_position,
            .brushes = brush_data,
        };
        
        return try loadFromData(allocator, map_data);
    }
    
    pub fn loadFromData(allocator: std.mem.Allocator, data: MapData) !Map {
        if (data.brushes.len > MAX_BRUSHES) {
            return MapError.TooManyBrushes;
        }
        
        // Allocate storage
        const brushes = try allocator.alloc(brush.Brush, data.brushes.len);
        const plane_normals = try allocator.alloc(Vec3, MAX_PLANES);
        const plane_distances = try allocator.alloc(f32, MAX_PLANES);
        
        var plane_idx: usize = 0;
        
        // Convert brush data to actual brushes
        for (data.brushes, 0..) |brush_data, i| {
            const planes_needed: usize = switch (brush_data) {
                .box => 6,
                .slope => 6,
            };
            
            if (plane_idx + planes_needed > MAX_PLANES) {
                allocator.free(brushes);
                allocator.free(plane_normals);
                allocator.free(plane_distances);
                return MapError.TooManyPlanes;
            }
            
            switch (brush_data) {
                .box => |box| {
                    createBoxBrush(
                        brushes[i..i+1],
                        plane_normals[plane_idx..plane_idx + 6],
                        plane_distances[plane_idx..plane_idx + 6],
                        Vec3.new(box.position[0], box.position[1], box.position[2]),
                        Vec3.new(box.size[0], box.size[1], box.size[2])
                    );
                    plane_idx += 6;
                },
                .slope => |slope| {
                    createSlopeBrush(
                        brushes[i..i+1],
                        plane_normals[plane_idx..plane_idx + 6],
                        plane_distances[plane_idx..plane_idx + 6],
                        Vec3.new(slope.position[0], slope.position[1], slope.position[2]),
                        slope.width,
                        slope.height,
                        slope.angle
                    );
                    plane_idx += 6;
                },
            }
        }
        
        // Create world
        const world = World.init(brushes, allocator) catch |err| {
            allocator.free(brushes);
            allocator.free(plane_normals);
            allocator.free(plane_distances);
            return err;
        };
        
        return Map{
            .allocator = allocator,
            .data = data,
            .world = world,
            .brushes = brushes,
            .plane_normals = plane_normals,
            .plane_distances = plane_distances,
        };
    }
    
    pub fn getSpawnPosition(self: *const Map) Vec3 {
        return Vec3.new(
            self.data.spawn_position[0],
            self.data.spawn_position[1],
            self.data.spawn_position[2]
        );
    }
    
    pub fn deinit(self: *Map) void {
        self.world.deinit();
        self.allocator.free(self.brushes);
        self.allocator.free(self.plane_normals);
        self.allocator.free(self.plane_distances);
    }
    
    fn createBoxBrush(
        brushes: []brush.Brush,
        normals: []Vec3,
        distances: []f32,
        center: Vec3,
        size: Vec3
    ) void {
        const half_size = Vec3.scale(size, 0.5);
        
        const box_normals = [6]Vec3{
            Vec3.new( 1,  0,  0), Vec3.new(-1,  0,  0),
            Vec3.new( 0,  1,  0), Vec3.new( 0, -1,  0),
            Vec3.new( 0,  0,  1), Vec3.new( 0,  0, -1),
        };
        const box_distances = [6]f32{
            -(center.data[0] + half_size.data[0]), center.data[0] - half_size.data[0],
            -(center.data[1] + half_size.data[1]), center.data[1] - half_size.data[1],
            -(center.data[2] + half_size.data[2]), center.data[2] - half_size.data[2],
        };
        
        @memcpy(normals[0..6], &box_normals);
        @memcpy(distances[0..6], &box_distances);
        
        brushes[0] = .{
            .planes = .{
                .normals = normals[0..6],
                .distances = distances[0..6],
            },
            .bounds = AABB.new(Vec3.sub(center, half_size), Vec3.add(center, half_size))
        };
    }
    
    fn createSlopeBrush(
        brushes: []brush.Brush,
        normals: []Vec3,
        distances: []f32,
        center: Vec3,
        width: f32,
        height: f32,
        angle_degrees: f32
    ) void {
        const angle = angle_degrees * (std.math.pi / 180.0);
        const slope_normal = Vec3.normalize(Vec3.new(0, @cos(angle), -@sin(angle)));
        const slope_point = Vec3.new(0, height, center.data[2] + width/2);
        
        const slope_normals = [6]Vec3{
            Vec3.new( 0, -1,  0), Vec3.new(-1,  0,  0), Vec3.new( 1,  0,  0),
            Vec3.new( 0,  0, -1), Vec3.new( 0,  0,  1), slope_normal,
        };
        const slope_distances = [6]f32{
            0.0, -width/2, -width/2,
            center.data[2] - width/2, -(center.data[2] + width/2),
            -Vec3.dot(slope_normal, slope_point),
        };
        
        @memcpy(normals[0..6], &slope_normals);
        @memcpy(distances[0..6], &slope_distances);
        
        brushes[0] = .{
            .planes = .{
                .normals = normals[0..6],
                .distances = distances[0..6],
            },
            .bounds = AABB.new(
                Vec3.new(-width/2, 0.0, center.data[2] - width/2),
                Vec3.new(width/2, height, center.data[2] + width/2)
            )
        };
    }
};