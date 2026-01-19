const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const saudio = sokol.audio;
const simgui = sokol.imgui;
const ig = @import("cimgui");

const math = @import("math");
const bvh = @import("lib/bvh.zig");
const brush = @import("lib/brush.zig");
const audio_lib = @import("lib/audio.zig");
const map_lib = @import("lib/map.zig");
const physics_mod = @import("resources/physics.zig");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const AABB = math.AABB;

// Module types
const Physics = physics_mod.Physics(.{});
const Renderer = @import("resources/render.zig").Renderer(.{});
const World = physics_mod.World;
const Map = map_lib.Map;

// Game state
const Game = struct {
    allocator: std.mem.Allocator,
    delta_time: f32 = 0,
    mouse_locked: bool = false,
    
    // Input state
    keys: packed struct { 
        w: bool = false, 
        a: bool = false, 
        s: bool = false, 
        d: bool = false, 
        sp: bool = false 
    } = .{},
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    
    // Systems
    physics: Physics = undefined,
    renderer: Renderer = undefined,
    
    // World data
    map: Map = undefined,
    
    fn init(self: *@This(), allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.physics = Physics.init(&mixer);
        self.renderer = Renderer.init(allocator);
        
        // Load map from JSON file
        self.map = Map.loadFromFile(allocator, "assets/game/map/test.json") catch |err| {
            std.log.err("Failed to load map: {}", .{err});
            // Create a minimal fallback map
            self.createFallbackMap(allocator);
            return;
        };
        
        std.log.info("Loaded map: {s}", .{self.map.data.name});
        std.log.info("Created {} brushes", .{self.map.brushes.len});
        for (self.map.brushes, 0..) |b, i| {
            std.log.info("  Brush {}: {} planes, bounds: ({d:.1},{d:.1},{d:.1}) to ({d:.1},{d:.1},{d:.1})", .{
                i, b.planes.len(),
                b.bounds.min.data[0], b.bounds.min.data[1], b.bounds.min.data[2],
                b.bounds.max.data[0], b.bounds.max.data[1], b.bounds.max.data[2]
            });
        }
    }
    
    fn createFallbackMap(self: *@This(), allocator: std.mem.Allocator) void {
        // Create a simple ground plane as fallback
        const fallback_brushes = allocator.alloc(map_lib.BrushData, 1) catch {
            std.log.err("Failed to allocate fallback brushes", .{});
            return;
        };
        defer allocator.free(fallback_brushes);
        
        fallback_brushes[0] = .{ .box = .{
            .position = .{ 0.0, -2.25, 0.0 },
            .size = .{ 100.0, 4.5, 100.0 }
        }};
        
        const fallback_data = map_lib.MapData{
            .name = "Fallback Map",
            .spawn_position = .{ 0.0, 3.0, 0.0 },
            .brushes = fallback_brushes,
        };
        
        self.map = Map.loadFromData(allocator, fallback_data) catch |err| {
            std.log.err("Failed to create fallback map: {}", .{err});
            return;
        };
    }
    
    fn buildWorldMesh(self: *@This()) !void {
        try self.renderer.buildWorldMesh(self.map.brushes);
    }
    
    fn deinit(self: *@This()) void {
        self.map.deinit();
        self.renderer.deinit();
    }
};

// Configuration constants
const MOUSE_SENSITIVITY: f32 = 0.002;
const PITCH_LIMIT: f32 = 1.5;
const EYE_HEIGHT: f32 = 0.6;

// Global state
var game: Game = undefined;
var initialized: bool = false;
var mixer: audio_lib.Mixer = undefined;
var background_music: ?*audio_lib.Audio = null;

export fn init() void {
    const allocator = std.heap.c_allocator;
    sg.setup(.{ .environment = sokol.glue.environment() });
    saudio.setup(.{ .stream_cb = audio });
    simgui.setup(.{});
    
    mixer = audio_lib.Mixer.init(allocator);
    
    // Load and start background music
    background_music = mixer.load("assets/game/music.pcm", 44100) catch |err| blk: {
        std.log.err("Failed to load background music: {}", .{err});
        break :blk null;
    };
    
    if (background_music) |music| {
        // Find free voice and start looping music
        for (&mixer.voices) |*voice| {
            if (voice.audio == null) {
                voice.* = .{ .audio = music, .looping = true, .volume = 0.3 };
                break;
            }
        }
    }
    
    game = .{ .allocator = allocator };
    game.init(allocator);
    
    game.buildWorldMesh() catch |err| {
        std.log.err("Failed to build world mesh: {}", .{err});
    };
    
    // Set initial player position from map
    game.physics.state.pos = game.map.getSpawnPosition();
    
    initialized = true;
}

export fn frame() void {
    game.delta_time = @as(f32, @floatCast(sapp.frameDuration()));
    
    // Handle mouse input
    game.physics.state.yaw += game.mouse_dx * MOUSE_SENSITIVITY;
    game.physics.state.pitch = std.math.clamp(game.physics.state.pitch + game.mouse_dy * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT);
    game.mouse_dx = 0;
    game.mouse_dy = 0;
    
    // Calculate input direction
    const fwd: f32 = if (game.keys.w) 1 else if (game.keys.s) -1 else 0;
    const right: f32 = if (game.keys.d) 1 else if (game.keys.a) -1 else 0;
    const wish_dir = math.wishdir(fwd, right, game.physics.state.yaw);
    
    // Update physics
    game.physics.update(&game.map.world, wish_dir, game.keys.sp, game.delta_time);
    
    // Render
    simgui.newFrame(.{ .width = sapp.width(), .height = sapp.height(), .delta_time = sapp.frameDuration() });
    
    const view = math.Mat4.viewMatrix(game.physics.state.pos, game.physics.state.yaw, game.physics.state.pitch, EYE_HEIGHT);
    game.renderer.render(view);
    game.renderer.renderCrosshair();
    
    simgui.render(); 
    sg.endPass(); 
    sg.commit();
}

export fn cleanup() void {
    initialized = false;
    saudio.shutdown();
    
    // Stop background music by clearing voices
    for (&mixer.voices) |*voice| {
        if (voice.audio == background_music) {
            voice.audio = null;
        }
    }
    
    game.deinit();
    mixer.deinit();
    simgui.shutdown(); 
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event) void {
    if (e == null) return;
    _ = simgui.handleEvent(e.*);
    
    if (!initialized) return;
    
    const d = e.*.type == .KEY_DOWN;
    
    switch (e.*.type) {
        .KEY_DOWN, .KEY_UP => switch (e.*.key_code) {
            .W => game.keys.w = d,
            .A => game.keys.a = d,
            .S => game.keys.s = d,
            .D => game.keys.d = d,
            .SPACE => game.keys.sp = d,
            .ESCAPE => {
                if (d and game.mouse_locked) {
                    game.mouse_locked = false;
                    sapp.showMouse(true);
                    sapp.lockMouse(false);
                }
            },
            else => {},
        },
        .MOUSE_DOWN => if (e.*.mouse_button == .LEFT and !game.mouse_locked) {
            game.mouse_locked = true;
            sapp.showMouse(false);
            sapp.lockMouse(true);
        },
        .MOUSE_MOVE => {
            if (game.mouse_locked) {
                game.mouse_dx += e.*.mouse_dx;
                game.mouse_dy += e.*.mouse_dy;
            }
        },
        else => {},
    }
}

fn audio(buf: [*c]f32, n: i32, c: i32) callconv(.c) void {
    if (n <= 0 or c <= 0) return;
    
    const n_usize: usize = @intCast(n);
    const c_usize: usize = @intCast(c);
    const total_samples = std.math.mul(usize, n_usize, c_usize) catch return;
    
    if (!initialized) { 
        for (0..total_samples) |i| buf[i] = 0; 
        return; 
    }
    
    for (0..n_usize) |f| {
        const sample = mixer.sample(44100.0);
        for (0..c_usize) |ch| buf[f * c_usize + ch] = sample;
    }
}

pub fn main() void {
    sapp.run(.{ 
        .init_cb = init, 
        .frame_cb = frame, 
        .cleanup_cb = cleanup, 
        .event_cb = event, 
        .width = 1024, 
        .height = 768, 
        .window_title = "FPS" 
    });
}