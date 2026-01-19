const std = @import("std");

pub const Audio = struct {
    samples: []f32,
    sample_rate: u32,
};

pub const Voice = struct {
    audio: ?*const Audio = null,
    position: f32 = 0,
    looping: bool = false,
    volume: f32 = 1.0,
};

pub const Mixer = struct {
    voices: [16]Voice = [_]Voice{.{}} ** 16,
    clips: std.ArrayListUnmanaged(Audio) = .{},
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Mixer {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Mixer) void {
        for (self.clips.items) |clip| {
            self.allocator.free(clip.samples);
        }
        self.clips.deinit(self.allocator);
    }
    
    pub fn load(self: *Mixer, path: []const u8, sample_rate: u32) !*Audio {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const num_samples = file_size / 2; // 16-bit = 2 bytes per sample
        const samples = try self.allocator.alloc(f32, num_samples);
        
        // Read and convert samples directly from raw PCM
        for (0..num_samples) |i| {
            var sample_bytes: [2]u8 = undefined;
            _ = try file.readAll(&sample_bytes);
            const sample_i16 = std.mem.readInt(i16, &sample_bytes, .little);
            samples[i] = @as(f32, @floatFromInt(sample_i16)) / 32768.0;
        }
        
        const audio = Audio{
            .samples = samples,
            .sample_rate = sample_rate,
        };
        
        try self.clips.append(self.allocator, audio);
        return &self.clips.items[self.clips.items.len - 1];
    }
    
    pub fn sample(self: *Mixer, target_sample_rate: f32) f32 {
        var mixed_sample: f32 = 0;
        
        for (&self.voices) |*voice| {
            if (voice.audio == null) continue;
            
            const audio = voice.audio.?;
            const pos_int = @as(usize, @intFromFloat(voice.position));
            
            if (pos_int >= audio.samples.len) {
                if (voice.looping) {
                    voice.position = 0;
                } else {
                    voice.audio = null;
                    continue;
                }
            }
            
            const sample_pos = @as(usize, @intFromFloat(voice.position));
            if (sample_pos < audio.samples.len) {
                mixed_sample += audio.samples[sample_pos] * voice.volume;
            }
            
            // Advance position
            const rate_ratio = @as(f32, @floatFromInt(audio.sample_rate)) / target_sample_rate;
            voice.position += rate_ratio;
        }
        
        return std.math.clamp(mixed_sample, -1.0, 1.0);
    }
};