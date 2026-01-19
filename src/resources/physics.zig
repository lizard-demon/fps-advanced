const std = @import("std");
const math = @import("math");
const bvh = @import("../lib/bvh.zig");
const brush = @import("../lib/brush.zig");
const audio = @import("../lib/audio.zig");

const Vec3 = math.Vec3;

pub const Config = struct {
    // Movement physics
    gravity: f32 = 6.0,
    jump_velocity: f32 = 2.0,
    max_speed: f32 = 4.0,
    air_speed: f32 = 0.7,
    acceleration: f32 = 70.0,
    friction: f32 = 5.0,
    
    // Collision detection
    margin: f32 = 0.02,
    slope_limit: f32 = 0.707, // 45 degrees
    slide_damping: f32 = 0.95,
    slide_damping_step: f32 = 0.05,
    max_slide_iterations: u32 = 3,
    
    // Player dimensions for brush expansion
    player_radius: f32 = 0.3,
    
    // BVH stack sizing
    min_stack_size: u32 = 32,
    stack_size_multiplier: u32 = 2,
    stack_size_padding: u32 = 8,
    
    // Audio
    jump_sound_duration: f32 = 0.15,
    audio_frequency: f32 = 500.0,
    audio_decay: f32 = 8.0,
    audio_amplitude: f32 = 0.3,
    
    // Thresholds
    friction_threshold: f32 = 0.1,
};

pub const World = struct {
    Bvh: bvh.BVH(brush.Brush),
    stack: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    brushes: []brush.Brush,
    
    const config = Config{};
    
    fn getBounds(b: brush.Brush) math.AABB {
        return b.bounds;
    }
    
    pub fn init(original_brushes: []const brush.Brush, allocator: std.mem.Allocator) !World {
        if (original_brushes.len == 0) return error.NoBrushes;
        
        // Expand brushes by player radius for point-based collision
        var brushes = try allocator.alloc(brush.Brush, original_brushes.len);
        for (original_brushes, 0..) |b, i| {
            brushes[i] = try b.expand(config.player_radius, allocator);
        }
        
        const Bvh = try bvh.BVH(brush.Brush).init(brushes, allocator, getBounds);
        const max_stack_size = @max(config.min_stack_size, config.stack_size_multiplier * @as(u32, @intFromFloat(@log2(@as(f32, @floatFromInt(Bvh.nodes.len))))) + config.stack_size_padding);
        
        var stack = std.ArrayListUnmanaged(u32){};
        try stack.ensureTotalCapacity(allocator, max_stack_size);
        
        return World{ 
            .Bvh = Bvh, 
            .stack = stack, 
            .allocator = allocator,
            .brushes = brushes,
        };
    }
    
    pub fn deinit(self: *World) void {
        // Free expanded brush plane data
        for (self.brushes) |b| {
            self.allocator.free(b.planes.normals);
            self.allocator.free(b.planes.distances);
        }
        self.allocator.free(self.brushes);
        
        self.Bvh.deinit();
        self.stack.deinit(self.allocator);
    }
    
    pub fn raycast(self: *World, ray_start: Vec3, ray_dir: Vec3, max_distance: f32) ?brush.Plane {
        var best_hit: ?brush.Plane = null;
        var best_distance: f32 = max_distance;
        
        // Create ray AABB for BVH traversal
        const ray_end = Vec3.add(ray_start, Vec3.scale(ray_dir, max_distance));
        const ray_bounds = math.AABB{
            .min = Vec3.min(ray_start, ray_end),
            .max = Vec3.max(ray_start, ray_end),
        };
        
        self.stack.clearRetainingCapacity();
        self.stack.appendAssumeCapacity(0);
        
        while (self.stack.items.len > 0) {
            const node_idx = self.stack.items[self.stack.items.len - 1];
            self.stack.items.len -= 1;
            if (node_idx >= self.Bvh.nodes.len) continue;
            
            const node_bounds = self.Bvh.nodes.get(node_idx).bounds;
            const node_type = self.Bvh.nodes.get(node_idx).node_type;
            if (!node_bounds.intersects(ray_bounds)) continue;
            
            if (node_type == .leaf) {
                const first = self.Bvh.nodes.get(node_idx).first;
                const count = self.Bvh.nodes.get(node_idx).count;
                const end_idx = @min(first + count, self.Bvh.indices.items.len);
                for (first..end_idx) |i| {
                    if (self.Bvh.items[self.Bvh.indices.items[i]].rayIntersect(ray_start, ray_dir, best_distance)) |hit| {
                        if (hit.distance < best_distance) {
                            best_distance = hit.distance;
                            best_hit = hit;
                        }
                    }
                }
            } else {
                const left = self.Bvh.nodes.get(node_idx).first;
                if (left + 1 < self.Bvh.nodes.len) self.stack.appendAssumeCapacity(left + 1);
                if (left < self.Bvh.nodes.len) self.stack.appendAssumeCapacity(left);
            }
        }
        
        return best_hit;
    }
};

pub fn Physics(comptime config: Config) type {
    return struct {
        const Self = @This();
        
        pub const State = struct {
            pos: Vec3 = Vec3.zero(),
            vel: Vec3 = Vec3.zero(),
            grounded: bool = false,
            yaw: f32 = 0,
            pitch: f32 = 0,
        };
        
        state: State = .{},
        jump_sound: ?*const audio.Audio = null,
        mixer: *audio.Mixer,
        
        pub fn init(mixer: *audio.Mixer) Self {
            var self = Self{ .mixer = mixer };
            // Load jump sound
            self.jump_sound = mixer.load("assets/player/jump.pcm", 44100) catch |err| blk: {
                std.log.err("Failed to load jump sound: {}", .{err});
                break :blk null;
            };
            return self;
        }
        
        pub fn update(self: *Self, world: *World, wish_dir: Vec3, jump: bool, dt: f32) void {
            // Apply friction before acceleration
            if (self.state.grounded) self.friction(dt);
            
            // Apply forces
            if (!self.state.grounded) self.state.vel.data[1] -= config.gravity * dt;
            if (jump and self.state.grounded) {
                self.state.vel.data[1] = config.jump_velocity;
                if (self.jump_sound) |sound| {
                    // Find free voice and play jump sound
                    for (&self.mixer.voices) |*voice| {
                        if (voice.audio == null) {
                            voice.* = .{ .audio = sound, .volume = 1.0 };
                            break;
                        }
                    }
                }
            }
            
            self.accelerate(wish_dir, dt);
            
            // Move and handle collision
            self.move(world, Vec3.scale(self.state.vel, dt));
        }
        
        fn accelerate(self: *Self, wish_dir: Vec3, dt: f32) void {
            const len = @sqrt(wish_dir.data[0] * wish_dir.data[0] + wish_dir.data[2] * wish_dir.data[2]);
            if (len < std.math.floatEpsAt(f32, len)) return;
            
            const wish = Vec3.scale(wish_dir, 1.0 / len);
            const max_vel = if (self.state.grounded) config.max_speed * len else @min(config.max_speed * len, config.air_speed);
            const current_vel = Vec3.dot(Vec3.new(self.state.vel.data[0], 0, self.state.vel.data[2]), wish);
            const accel = @min(config.acceleration * dt, @max(0, max_vel - current_vel));
            
            self.state.vel.data[0] += wish.data[0] * accel;
            self.state.vel.data[2] += wish.data[2] * accel;
        }
        
        fn friction(self: *Self, dt: f32) void {
            const speed = @sqrt(self.state.vel.data[0] * self.state.vel.data[0] + self.state.vel.data[2] * self.state.vel.data[2]);
            if (speed <= config.friction_threshold) {
                self.state.vel.data[0] = 0;
                self.state.vel.data[2] = 0;
            } else {
                const factor = @max(0, speed - speed * config.friction * dt) / speed;
                self.state.vel.data[0] *= factor;
                self.state.vel.data[2] *= factor;
            }
        }
        
        fn move(self: *Self, world: *World, delta: Vec3) void {
            var vel = delta;
            self.state.grounded = false;
            
            for (0..config.max_slide_iterations) |_| {
                const len = Vec3.length(vel);
                if (len < std.math.floatEpsAt(f32, len)) break;
                
                // Prevent tunneling by ensuring minimum raycast distance
                const min_raycast_dist = config.margin * 2.0;
                const raycast_len = @max(len, min_raycast_dist);
                
                if (world.raycast(self.state.pos, Vec3.scale(vel, 1.0 / len), raycast_len)) |hit| {
                    self.state.pos = Vec3.add(self.state.pos, Vec3.scale(vel, @max(0, hit.distance - config.margin) / len));
                    
                    const dot_vel = Vec3.dot(vel, hit.normal);
                    if (dot_vel >= 0) break;
                    
                    if (hit.normal.data[1] > config.slope_limit) self.state.grounded = true;
                    
                    vel = Vec3.sub(vel, Vec3.scale(hit.normal, dot_vel));
                    
                    const dot_state = Vec3.dot(self.state.vel, hit.normal);
                    if (dot_state < 0) self.state.vel = Vec3.sub(self.state.vel, Vec3.scale(hit.normal, dot_state));
                } else {
                    self.state.pos = Vec3.add(self.state.pos, vel);
                    break;
                }
            }
        }
    };
}