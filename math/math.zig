const std = @import("std");

pub const Vec3 = packed struct {
    data: @Vector(3, f32),

    pub inline fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .data = .{ x, y, z } };
    }
    pub inline fn zero() Vec3 {
        return .{ .data = @splat(0) };
    }
    pub inline fn one() Vec3 {
        return .{ .data = @splat(1) };
    }
    pub inline fn add(v: Vec3, o: Vec3) Vec3 {
        return .{ .data = v.data + o.data };
    }
    pub inline fn sub(v: Vec3, o: Vec3) Vec3 {
        return .{ .data = v.data - o.data };
    }
    pub inline fn mul(v: Vec3, o: Vec3) Vec3 {
        return .{ .data = v.data * o.data };
    }
    pub inline fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .data = v.data * @as(@Vector(3, f32), @splat(s)) };
    }
    pub inline fn dot(v: Vec3, o: Vec3) f32 {
        return @reduce(.Add, v.data * o.data);
    }
    pub inline fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }
    pub inline fn dist(a: Vec3, b: Vec3) f32 {
        return length(sub(a, b));
    }
    pub inline fn normalize(v: Vec3) Vec3 {
        const l = v.length();
        return if (l > 0) v.scale(1.0 / l) else v;
    }
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(
            a.data[1] * b.data[2] - a.data[2] * b.data[1], 
            a.data[2] * b.data[0] - a.data[0] * b.data[2], 
            a.data[0] * b.data[1] - a.data[1] * b.data[0]
        );
    }
    pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return add(a, sub(b, a).scale(t));
    }
    pub inline fn min(a: Vec3, b: Vec3) Vec3 {
        return .{ .data = @min(a.data, b.data) };
    }
    pub inline fn max(a: Vec3, b: Vec3) Vec3 {
        return .{ .data = @max(a.data, b.data) };
    }
};

pub const AABB = packed struct {
    min: Vec3,
    max: Vec3,
    
    pub fn new(min: Vec3, max: Vec3) AABB {
        return .{ .min = min, .max = max };
    }
    
    pub fn fromCenterSize(center: Vec3, size: Vec3) AABB {
        const half = Vec3.scale(size, 0.5);
        return .{ .min = Vec3.sub(center, half), .max = Vec3.add(center, half) };
    }
    
    pub fn intersects(self: AABB, other: AABB) bool {
        return (self.min.data[0] <= other.max.data[0] and self.max.data[0] >= other.min.data[0] and
                self.min.data[1] <= other.max.data[1] and self.max.data[1] >= other.min.data[1] and
                self.min.data[2] <= other.max.data[2] and self.max.data[2] >= other.min.data[2]);
    }
    
    pub fn union_with(self: AABB, other: AABB) AABB {
        return .{ .min = Vec3.min(self.min, other.min), .max = Vec3.max(self.max, other.max) };
    }
    
    pub fn containsPoint(self: AABB, point: Vec3) bool {
        return (point.data[0] >= self.min.data[0] and point.data[0] <= self.max.data[0] and
                point.data[1] >= self.min.data[1] and point.data[1] <= self.max.data[1] and
                point.data[2] >= self.min.data[2] and point.data[2] <= self.max.data[2]);
    }
    
    pub fn surface_area(self: AABB) f32 {
        const d = Vec3.sub(self.max, self.min);
        return 2.0 * (d.data[0] * d.data[1] + d.data[1] * d.data[2] + d.data[2] * d.data[0]);
    }
};

pub const Mat4 = struct {
    data: [16]f32,

    pub inline fn identity() Mat4 {
        return .{ .data = .{ 
            1, 0, 0, 0, 
            0, 1, 0, 0, 
            0, 0, 1, 0, 
            0, 0, 0, 1 
        } };
    }

    pub inline fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        inline for (0..4) |c| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a.data[k * 4 + row] * b.data[c * 4 + k];
                r.data[c * 4 + row] = s;
            }
        }
        return r;
    }

    pub inline fn mulVec(m: Mat4, v: Vec3) @Vector(4, f32) {
        const x = m.data[0] * v.data[0] + m.data[4] * v.data[1] + m.data[8] * v.data[2] + m.data[12];
        const y = m.data[1] * v.data[0] + m.data[5] * v.data[1] + m.data[9] * v.data[2] + m.data[13];
        const z = m.data[2] * v.data[0] + m.data[6] * v.data[1] + m.data[10] * v.data[2] + m.data[14];
        const w = m.data[3] * v.data[0] + m.data[7] * v.data[1] + m.data[11] * v.data[2] + m.data[15];
        return .{ x, y, z, w };
    }

    pub inline fn translate(v: Vec3) Mat4 {
        return .{ .data = .{ 
            1, 0, 0, 0, 
            0, 1, 0, 0, 
            0, 0, 1, 0, 
            v.data[0], v.data[1], v.data[2], 1 
        } };
    }

    pub inline fn scale(v: Vec3) Mat4 {
        return .{ .data = .{ 
            v.data[0], 0, 0, 0, 
            0, v.data[1], 0, 0, 
            0, 0, v.data[2], 0, 
            0, 0, 0, 1 
        } };
    }
    
    pub inline fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .data = .{
            s.data[0], u.data[0], -f.data[0], 0,
            s.data[1], u.data[1], -f.data[1], 0,
            s.data[2], u.data[2], -f.data[2], 0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1
        }};
    }
    
    pub inline fn viewMatrix(pos: Vec3, yaw: f32, pitch: f32, eye_height: f32) Mat4 {
        const eye = Vec3.add(pos, Vec3.new(0, eye_height, 0));
        const cy, const sy = .{ @cos(yaw), @sin(yaw) };
        const cp, const sp = .{ @cos(pitch), @sin(pitch) };
        return Mat4{ .data = .{ 
            cy, sy*sp, -sy*cp, 0, 
            0, cp, sp, 0, 
            sy, -cy*sp, cy*cp, 0, 
            -eye.data[0]*cy - eye.data[2]*sy, 
            -eye.data[0]*sy*sp - eye.data[1]*cp + eye.data[2]*cy*sp, 
            eye.data[0]*sy*cp - eye.data[1]*sp - eye.data[2]*cy*cp, 
            1 
        }};
    }
};

pub inline fn perspective(fov: f32, asp: f32, n: f32, f: f32) Mat4 {
    const t = @tan(fov * std.math.pi / 360.0) * n;
    const r = t * asp;
    return .{ .data = .{ n / r, 0, 0, 0, 0, n / t, 0, 0, 0, 0, -(f + n) / (f - n), -1, 0, 0, -(2 * f * n) / (f - n), 0 } };
}

pub inline fn wishdir(fwd: f32, right: f32, yaw: f32) Vec3 {
    const fwd_vec = Vec3.new(@sin(yaw), 0, -@cos(yaw));
    const side_vec = Vec3.new(@cos(yaw), 0, @sin(yaw));
    return Vec3.add(Vec3.scale(fwd_vec, fwd), Vec3.scale(side_vec, right));
}