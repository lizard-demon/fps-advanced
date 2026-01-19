const std = @import("std");
const math = @import("math");

const Vec3 = math.Vec3;
const AABB = math.AABB;

pub const Plane = struct { normal: Vec3, distance: f32 };

pub const Planes = struct {
    normals: []const Vec3,
    distances: []const f32,
    
    pub fn len(self: Planes) usize {
        return self.normals.len;
    }
    
    pub fn distanceToPoint(self: Planes, index: usize, point: Vec3) f32 {
        return Vec3.dot(self.normals[index], point) + self.distances[index];
    }
    
    pub fn rayIntersect(self: Planes, index: usize, ray_start: Vec3, ray_dir: Vec3) ?f32 {
        const normal = self.normals[index];
        const distance = self.distances[index];
        
        const denom = Vec3.dot(normal, ray_dir);
        if (@abs(denom) < std.math.floatEpsAt(f32, denom)) return null; // Ray parallel to plane
        
        const t = -(Vec3.dot(normal, ray_start) + distance) / denom;
        return if (t >= 0) t else null;
    }
};

pub const Brush = struct {
    planes: Planes,
    bounds: AABB,
    
    pub fn expand(self: Brush, radius: f32, allocator: std.mem.Allocator) !Brush {
        // Expand each plane outward by the radius
        var expanded_normals = try allocator.alloc(Vec3, self.planes.len());
        var expanded_distances = try allocator.alloc(f32, self.planes.len());
        
        for (0..self.planes.len()) |i| {
            expanded_normals[i] = self.planes.normals[i];
            expanded_distances[i] = self.planes.distances[i] - radius; // Move plane outward
        }
        
        // Expand bounds by radius
        const radius_vec = Vec3.new(radius, radius, radius);
        const expanded_bounds = AABB{
            .min = Vec3.sub(self.bounds.min, radius_vec),
            .max = Vec3.add(self.bounds.max, radius_vec),
        };
        
        return Brush{
            .planes = .{
                .normals = expanded_normals,
                .distances = expanded_distances,
            },
            .bounds = expanded_bounds,
        };
    }
    
    pub fn rayIntersect(self: Brush, ray_start: Vec3, ray_dir: Vec3, max_distance: f32) ?Plane {
        var entry_time: f32 = 0;
        var exit_time: f32 = max_distance;
        var hit_normal: Vec3 = Vec3.zero();
        
        for (0..self.planes.len()) |i| {
            const normal = self.planes.normals[i];
            
            if (self.planes.rayIntersect(i, ray_start, ray_dir)) |t| {
                const dot = Vec3.dot(normal, ray_dir);
                if (dot < 0) { // Entering
                    if (t > entry_time) {
                        entry_time = t;
                        hit_normal = normal;
                    }
                } else { // Exiting
                    if (t < exit_time) {
                        exit_time = t;
                    }
                }
            } else {
                // Ray parallel to plane - check if we're on the wrong side
                if (self.planes.distanceToPoint(i, ray_start) > 0) return null;
            }
        }
        
        if (entry_time <= exit_time and entry_time <= max_distance and entry_time >= std.math.floatEpsAt(f32, entry_time)) {
            return Plane{ .normal = hit_normal, .distance = entry_time };
        }
        
        return null;
    }
};