//! Stub audio playback for targets that do not link miniaudio yet. It
//! reports the capability absent, so a lens with a sound trigger degrades to
//! silence instead of failing.
const std = @import("std");

pub const Mixer = struct {
    handle: *anyopaque,
    channels: u32,

    pub fn create(sample_rate: u32, channels: u32) !Mixer {
        _ = sample_rate;
        _ = channels;
        return error.MixerUnsupported;
    }

    pub fn destroy(self: *Mixer) void {
        _ = self;
    }

    pub fn load(self: *Mixer, path: []const u8) !u32 {
        _ = self;
        _ = path;
        return error.MixerUnsupported;
    }

    pub fn loadMemory(self: *Mixer, data: []const u8) !u32 {
        _ = self;
        _ = data;
        return error.MixerUnsupported;
    }

    pub fn play(self: *Mixer, sound_id: u32, loop: bool, gain: f32) void {
        _ = self;
        _ = sound_id;
        _ = loop;
        _ = gain;
    }

    pub fn activeVoices(self: *const Mixer) u32 {
        _ = self;
        return 0;
    }

    pub fn pull(self: *Mixer, out: []i16, frames: u32) void {
        _ = self;
        _ = frames;
        @memset(out, 0);
    }
};
