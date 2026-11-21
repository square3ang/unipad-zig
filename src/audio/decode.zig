//! Up-front audio decoder (WAV, MP3, OGG Vorbis, FLAC) with Hermite resampling to stereo f32.
const std = @import("std");
const c = @import("c");

pub const Sample = struct {
    data: []f32 = &.{}, // stereo interleaved f32 frames
    pub fn frames(s: Sample) usize {
        return s.data.len / 2;
    }
};

const max_seconds = 30 * 60;
const max_raw_samples = max_seconds * 48000 * 2;
const Raw = struct { samples: []f32, channels: u32, rate: u32 };

fn lower(path: []const u8, buf: []u8) []const u8 {
    return std.ascii.lowerString(buf, path[path.len -| @min(path.len, buf.len)..]);
}

fn decodeRaw(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) !Raw {
    var ext_buf: [8]u8 = undefined;
    const ext = lower(std.fs.path.extension(name), &ext_buf);
    const try_order: [4]u8 = if (std.mem.eql(u8, ext, ".ogg"))
        .{ 'o', 'w', 'f', 'm' }
    else if (std.mem.eql(u8, ext, ".flac"))
        .{ 'f', 'w', 'o', 'm' }
    else if (std.mem.eql(u8, ext, ".mp3"))
        .{ 'm', 'w', 'o', 'f' }
    else
        .{ 'w', 'o', 'f', 'm' };

    for (try_order) |t| switch (t) {
        'w' => {
            var w: c.drwav = undefined;
            if (c.drwav_init_memory(&w, bytes.ptr, bytes.len, null) != 0) {
                defer _ = c.drwav_uninit(&w);
                if (try readAll(gpa, &w, w.channels, w.sampleRate, c.drwav_read_pcm_frames_f32)) |raw| return raw;
            }
        },
        'f' => if (bytes.len >= 22 and std.mem.startsWith(u8, bytes, "fLaC")) {
            if (c.drflac_open_memory(bytes.ptr, bytes.len, null)) |f| {
                defer c.drflac_close(f);
                const rate = @as(u32, bytes[18]) << 12 | @as(u32, bytes[19]) << 4 | bytes[20] >> 4;
                const channels = (bytes[20] >> 1 & 7) + 1;
                if (try readAll(gpa, f, channels, rate, c.drflac_read_pcm_frames_f32)) |raw| return raw;
            }
        },
        'm' => {
            var m: c.drmp3 = undefined;
            if (c.drmp3_init_memory(&m, bytes.ptr, bytes.len, null) != 0) {
                defer c.drmp3_uninit(&m);
                if (try readAll(gpa, &m, m.channels, m.sampleRate, c.drmp3_read_pcm_frames_f32)) |raw| return raw;
            }
        },
        'o' => if (bytes.len <= std.math.maxInt(c_int)) {
            var err: c_int = 0;
            if (c.stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &err, null)) |v| {
                defer c.stb_vorbis_close(v);
                const info = c.stb_vorbis_get_info(v);
                var ogg: Ogg = .{ .v = v, .channels = info.channels };
                if (info.channels > 0) {
                    if (try readAll(gpa, &ogg, @intCast(info.channels), info.sample_rate, Ogg.read)) |raw| return raw;
                }
            }
        },
        else => unreachable,
    };
    return error.UndecodableAudio;
}

fn readAll(gpa: std.mem.Allocator, dec: anytype, channels: u32, rate: u32, comptime read: anytype) !?Raw {
    if (channels == 0 or rate == 0) return null;
    const chunk = 4096;
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const room = try out.addManyAsSlice(gpa, chunk * channels);
        const got: usize = @intCast(@min(read(dec, chunk, room.ptr), chunk));
        out.shrinkRetainingCapacity(out.items.len - (chunk - got) * channels);
        if (got == 0) break;
        if (out.items.len > max_raw_samples or out.items.len / channels > max_seconds * @as(usize, rate)) return error.UndecodableAudio;
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return .{ .samples = try out.toOwnedSlice(gpa), .channels = channels, .rate = rate };
}

const Ogg = struct {
    v: *c.stb_vorbis,
    channels: c_int,

    fn read(o: *Ogg, frames: u64, buf: [*]f32) u64 {
        return @intCast(@max(c.stb_vorbis_get_samples_float_interleaved(o.v, o.channels, buf, @intCast(frames * @as(u64, @intCast(o.channels)))), 0));
    }
};

fn hermite(x0: f32, x1: f32, x2: f32, x3: f32, t: f32) f32 {
    const a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3;
    const b = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
    const cc = -0.5 * x0 + 0.5 * x2;
    return ((a * t + b) * t + cc) * t + x1;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8, out_rate: u32) !Sample {
    const raw = try decodeRaw(gpa, bytes, name);
    defer gpa.free(raw.samples);
    return resample(gpa, raw.samples, raw.channels, raw.rate, out_rate);
}

fn resample(gpa: std.mem.Allocator, samples: []const f32, ch: u32, rate: u32, out_rate: u32) !Sample {
    const in_frames = samples.len / ch;
    if (rate == 0 or in_frames == 0) return error.UndecodableAudio;
    const ratio = @as(f64, @floatFromInt(rate)) / @as(f64, @floatFromInt(out_rate));
    const out_len = @ceil(@as(f64, @floatFromInt(in_frames)) / ratio);
    if (out_len > @as(f64, @floatFromInt(max_seconds * out_rate))) return error.UndecodableAudio;
    const out_frames: usize = @intFromFloat(out_len);
    const out = try gpa.alloc(f32, out_frames * 2);
    const at = struct {
        fn f(s: []const f32, chn: u32, i: i64, side: u32, n: usize) f32 {
            const idx: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intCast(n)) - 1));
            return s[idx * chn + @min(side, chn - 1)];
        }
    }.f;
    if (rate == out_rate) {
        for (0..out_frames) |i| {
            out[i * 2] = at(samples, ch, @intCast(i), 0, in_frames);
            out[i * 2 + 1] = at(samples, ch, @intCast(i), 1, in_frames);
        }
    } else {
        for (0..out_frames) |i| {
            const pos = @as(f64, @floatFromInt(i)) * ratio;
            const k: i64 = @intFromFloat(@floor(pos));
            const t: f32 = @floatCast(pos - @as(f64, @floatFromInt(k)));
            for (0..2) |side| {
                const s: u32 = @intCast(side);
                out[i * 2 + side] = hermite(
                    at(samples, ch, k - 1, s, in_frames),
                    at(samples, ch, k, s, in_frames),
                    at(samples, ch, k + 1, s, in_frames),
                    at(samples, ch, k + 2, s, in_frames),
                    t,
                );
            }
        }
    }
    return .{ .data = out };
}
