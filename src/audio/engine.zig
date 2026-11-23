//! Lock-free polyphonic audio engine: direct ALSA on Linux, PortAudio on other OSes.
const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");
const decode = @import("decode.zig");
const alsa = if (builtin.os.tag == .linux) @import("alsa.zig") else struct {};

pub const max_voices = 256;
const feed_max = 4096;
const device_key_max = 512;

const Voice = struct {
    data: []const f32 = &.{}, // stereo interleaved f32
    pos: f64 = 0, // frame position (not sample index)
    age: u32 = 0, // output frames rendered since voice start (for de-click fade-in)
    rate: f32 = 1.0,
    gain: f32 = 1.0,
    /// -1 = infinite loop until stopVoice, 0 = play remaining once, N > 0 = N additional loops.
    loops_left: i32 = 0,
    stopping: bool = false,
    stop_rem: u32 = 0,
    key: u32 = 0,
};

const Cmd = union(enum) {
    play: struct { sample_id: u32, loop: i32, rate: f32, gain: f32, key: u32 },
    stop_voice: u32,
    stop_all,
    set_paused: bool,
    set_gain: f32,
    set_anti_pop: bool,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    rate: u32 = 48000,
    samples: []const decode.Sample = &.{},
    voices: [max_voices]Voice = @splat(.{}),
    active_voices: usize = 0,
    paused: bool = false,
    gain: f32 = 1.0,
    target_gain: f32 = 1.0,
    anti_pop: bool = true,
    dc_in: [2]f32 = .{ 0, 0 },
    dc_out: [2]f32 = .{ 0, 0 },
    next_voice_key: std.atomic.Value(u32) = .init(1),
    cmd_buf: [4096]Cmd = undefined,
    cmd_head: std.atomic.Value(u32) = .init(0),
    cmd_tail: std.atomic.Value(u32) = .init(0),
    cmd_lock: std.atomic.Value(bool) = .init(false),
    feed_thread: ?*c.SDL_Thread = null,
    feed_frames: u32 = 128,
    feed_quit: std.atomic.Value(bool) = .init(false),
    xruns: std.atomic.Value(u32) = .init(0),
    is_null: bool = false,
    device: []const u8 = "",

    // OS-specific stream handles
    alsa_out: if (builtin.os.tag == .linux) ?alsa.Out else void = if (builtin.os.tag == .linux) null else {},
    pa_ready: if (builtin.os.tag != .linux) bool else void = if (builtin.os.tag != .linux) false else {},
    pa_stream: if (builtin.os.tag != .linux) ?*c.PaStream else void = if (builtin.os.tag != .linux) null else {},

    pub fn create(gpa: std.mem.Allocator) !*Engine {
        const e = try gpa.create(Engine);
        e.* = .{ .gpa = gpa };
        return e;
    }

    pub fn destroy(e: *Engine) void {
        e.close();
        if (builtin.os.tag != .linux) {
            if (e.pa_ready) _ = c.Pa_Terminate();
        }
        e.gpa.destroy(e);
    }

    pub fn open(e: *Engine, want_rate: u32, frames: u32, prefer_null: bool, device: []const u8) !void {
        e.rate = want_rate;
        e.device = device;
        e.is_null = false;
        e.xruns.store(0, .monotonic);
        if (prefer_null) return e.openNull();

        if (builtin.os.tag == .linux) {
            if (device.len > 0) {
                if (e.openAlsa(device, frames)) return;
                std.log.warn("ALSA device \"{s}\" failed, trying default", .{device});
            }
            if (e.openAlsa("default", frames)) return;
            std.log.warn("ALSA default failed, falling back to null audio", .{});
            return e.openNull();
        } else {
            if (!e.pa_ready) {
                if (c.Pa_Initialize() != c.paNoError) return e.openNull();
                e.pa_ready = true;
            }
            if (device.len > 0) {
                if (namedPaDevice(device)) |dev| {
                    const ty = c.Pa_GetHostApiInfo(c.Pa_GetDeviceInfo(dev).*.hostApi).*.type;
                    if (e.openPaOn(ty, dev, want_rate, frames)) return;
                }
                std.log.warn("audio device \"{s}\" did not open, using default", .{device});
            }
            const order: []const c.PaHostApiTypeId = switch (builtin.os.tag) {
                .windows => &.{ c.paASIO, c.paWASAPI },
                .macos => &.{c.paCoreAudio},
                else => &.{},
            };
            for (order) |ty| if (e.openPaDefaultOf(ty, frames)) return;
            const dev = c.Pa_GetDefaultOutputDevice();
            if (dev >= 0 and e.tryOpenPa(c.paInDevelopment, dev, want_rate, frames, false)) return;
            return e.openNull();
        }
    }

    pub fn reopen(e: *Engine, frames: u32, device: []const u8) void {
        const clamped = @min(frames, feed_max);
        if (!e.is_null and std.mem.eql(u8, e.device, device) and clamped == e.feed_frames) return;
        e.close();
        e.open(e.rate, clamped, false, device) catch |err| std.log.err("audio reopen failed: {t}", .{err});
    }

    pub fn close(e: *Engine) void {
        if (e.feed_thread) |t| {
            e.feed_quit.store(true, .release);
            c.SDL_WaitThread(t, null);
            e.feed_thread = null;
        }
        if (builtin.os.tag == .linux) {
            if (e.alsa_out) |*o| {
                o.close();
                e.alsa_out = null;
            }
        } else {
            if (e.pa_stream) |s| {
                _ = c.Pa_StopStream(s);
                _ = c.Pa_CloseStream(s);
                e.pa_stream = null;
            }
        }
    }

    pub fn outputDevices(e: *const Engine, a: std.mem.Allocator) []const []const u8 {
        if (builtin.os.tag == .linux) {
            return alsa.outputNames(a);
        } else {
            if (!e.pa_ready) return &.{};
            var names: std.ArrayList([]const u8) = .empty;
            var buf: [device_key_max]u8 = undefined;
            var dev: c.PaDeviceIndex = 0;
            while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
                const key = a.dupe(u8, paOutputKey(&buf, dev) orelse continue) catch return names.items;
                names.append(a, key) catch return names.items;
            }
            return names.items;
        }
    }

    /// Safely swaps the loaded sample table without racing the audio thread.
    pub fn setSamples(e: *Engine, samples: []const decode.Sample) void {
        e.push(.{ .set_paused = true });
        e.push(.stop_all);
        var waited: u32 = 0;
        while (e.cmd_tail.load(.acquire) != e.cmd_head.load(.acquire) and waited < 200) : (waited += 1) {
            c.SDL_Delay(1);
        }
        c.SDL_Delay(2 + @as(u32, 2048) * 1000 / @max(e.rate, 1));
        e.samples = samples;
        e.active_voices = 0;
        e.push(.{ .set_paused = false });
    }

    /// Plays `sample_id`. `loop`: -1 = infinite until stopVoice, 0 = once, N = N extra repeats.
    pub fn play(e: *Engine, sample_id: u32, loop: i32, rate: f32) u32 {
        var key = e.next_voice_key.fetchAdd(1, .monotonic);
        if (key == 0) key = e.next_voice_key.fetchAdd(1, .monotonic);
        const safe_rate = std.math.clamp(rate, 0.1, 4.0);
        e.push(.{ .play = .{ .sample_id = sample_id, .loop = loop, .rate = safe_rate, .gain = 1.0, .key = key } });
        return key;
    }

    pub fn stopVoice(e: *Engine, key: u32) void {
        if (key == 0) return;
        e.push(.{ .stop_voice = key });
    }

    pub fn stopAll(e: *Engine) void {
        e.push(.stop_all);
    }

    pub fn setGain(e: *Engine, gain: f32) void {
        e.push(.{ .set_gain = std.math.clamp(gain, 0.0, 2.0) });
    }

    pub fn setAntiPop(e: *Engine, on: bool) void {
        e.push(.{ .set_anti_pop = on });
    }

    fn push(e: *Engine, cmd: Cmd) void {
        while (e.cmd_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer e.cmd_lock.store(false, .release);
        const h = e.cmd_head.load(.monotonic);
        if (h -% e.cmd_tail.load(.acquire) >= e.cmd_buf.len) return;
        e.cmd_buf[h % e.cmd_buf.len] = cmd;
        e.cmd_head.store(h +% 1, .release);
    }

    fn openAlsa(e: *Engine, name: []const u8, frames: u32) bool {
        if (builtin.os.tag != .linux) return false;
        const out = alsa.Out.open(name, e.rate, frames, feed_max) orelse return false;
        e.alsa_out = out;
        e.feed_frames = out.period;
        e.feed_quit.store(false, .release);
        e.feed_thread = c.SDL_CreateThread(alsaThread, "unipad-alsa", e);
        return true;
    }

    fn alsaThread(ud: ?*anyopaque) callconv(.c) c_int {
        if (builtin.os.tag != .linux) return 0;
        const e: *Engine = @ptrCast(@alignCast(ud));
        raiseAudioPriority();
        const out = &e.alsa_out.?;
        var buf: [feed_max * 2]f32 = undefined;
        var scratch: [feed_max * alsa.max_channels * 4]u8 = undefined;
        // Prefault stack pages before entering the 1-period real-time loop.
        @memset(&buf, 0);
        @memset(&scratch, 0);
        while (!e.feed_quit.load(.acquire)) {
            var xrun = false;
            const ready = out.waitRoom(&xrun);
            if (xrun) _ = e.xruns.fetchAdd(1, .monotonic);
            if (!ready) continue;
            e.mix(&buf, out.period);
            if (out.write(buf[0 .. out.period * 2], &scratch)) {
                _ = e.xruns.fetchAdd(1, .monotonic);
            }
        }
        return 0;
    }

    fn onSigXcpu(_: std.os.linux.SIG) callconv(.c) void {
        // Async-signal-safe: demote this RT thread to normal scheduling so RLIMIT_RTTIME never kills the process.
        const normal: std.os.linux.sched_param = .{ .priority = 0 };
        _ = std.os.linux.sched_setscheduler(0, .{ .mode = .NORMAL }, &normal);
    }

    fn raiseAudioPriority() void {
        if (builtin.os.tag != .linux) return;
        const linux = std.os.linux;
        const act: linux.Sigaction = .{
            .handler = .{ .handler = onSigXcpu },
            .mask = linux.sigemptyset(),
            .flags = linux.SA.RESTART,
        };
        _ = linux.sigaction(.XCPU, &act, null);

        // Prefer direct sched_setscheduler when RLIMIT_RTPRIO allows it: avoids SDL/rtkit clamping RLIMIT_RTTIME to 100ms.
        const param: linux.sched_param = .{ .priority = 20 };
        if (linux.errno(linux.sched_setscheduler(0, .{ .mode = .RR, .RESET_ON_FORK = true }, &param)) == .SUCCESS) return;

        const rr: c_int = @backingInt(linux.SCHED.Mode.RR);
        if (c.SDL_SetLinuxThreadPriorityAndPolicy(linux.gettid(), c.SDL_THREAD_PRIORITY_TIME_CRITICAL, rr)) return;
        std.log.warn("audio thread stays non-realtime: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_TIME_CRITICAL);
    }

    fn openNull(e: *Engine) !void {
        e.is_null = true;
        e.feed_frames = 512;
        e.feed_quit.store(false, .release);
        e.feed_thread = c.SDL_CreateThread(nullThread, "unipad-null", e);
    }

    fn nullThread(ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(ud));
        var buf: [512 * 2]f32 = undefined;
        var next = c.SDL_GetTicksNS();
        while (!e.feed_quit.load(.acquire)) {
            const now = c.SDL_GetTicksNS();
            if (now < next) {
                c.SDL_DelayNS(next - now);
                continue;
            }
            e.mix(&buf, 512);
            next += @as(u64, 512) * 1_000_000_000 / @max(e.rate, 1);
        }
        return 0;
    }

    // --- PortAudio backend (non-Linux only) ---

    fn paNameOf(ty: c.PaHostApiTypeId) [:0]const u8 {
        if (builtin.os.tag == .linux) unreachable;
        return switch (ty) {
            c.paASIO => "ASIO",
            c.paWASAPI => "WASAPI",
            c.paCoreAudio => "CoreAudio",
            else => "other",
        };
    }

    fn paOutputKey(buf: []u8, dev: c.PaDeviceIndex) ?[]const u8 {
        if (builtin.os.tag == .linux) unreachable;
        const info = c.Pa_GetDeviceInfo(dev);
        if (info == null or info.*.maxOutputChannels < 2) return null;
        const api = c.Pa_GetHostApiInfo(info.*.hostApi);
        if (api == null) return null;
        const name = std.mem.span(info.*.name);
        if (builtin.os.tag == .windows) return std.fmt.bufPrint(buf, "{s}: {s}", .{ paNameOf(api.*.type), name }) catch null;
        return if (name.len <= buf.len) name else null;
    }

    fn namedPaDevice(name: []const u8) ?c.PaDeviceIndex {
        if (builtin.os.tag == .linux) unreachable;
        var buf: [device_key_max]u8 = undefined;
        var dev: c.PaDeviceIndex = 0;
        while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
            if (std.mem.eql(u8, paOutputKey(&buf, dev) orelse continue, name)) return dev;
        }
        return null;
    }

    fn openPaDefaultOf(e: *Engine, ty: c.PaHostApiTypeId, frames: u32) bool {
        if (builtin.os.tag == .linux) unreachable;
        const index = c.Pa_HostApiTypeIdToHostApiIndex(ty);
        if (index < 0) return false;
        const info = c.Pa_GetHostApiInfo(index);
        if (info == null or info.*.defaultOutputDevice < 0) return false;
        return e.openPaOn(ty, info.*.defaultOutputDevice, e.rate, frames);
    }

    fn openPaOn(e: *Engine, ty: c.PaHostApiTypeId, dev: c.PaDeviceIndex, rate: u32, frames: u32) bool {
        if (builtin.os.tag == .linux) unreachable;
        return e.tryOpenPa(ty, dev, rate, frames, true) or e.tryOpenPa(ty, dev, rate, frames, false);
    }

    fn tryOpenPa(e: *Engine, ty: c.PaHostApiTypeId, dev: c.PaDeviceIndex, rate: u32, frames: u32, exclusive: bool) bool {
        if (builtin.os.tag == .linux) unreachable;
        const dinfo = c.Pa_GetDeviceInfo(dev);
        if (dinfo == null) return false;
        var out: c.PaStreamParameters = .{
            .device = dev,
            .channelCount = 2,
            .sampleFormat = c.paFloat32,
            .suggestedLatency = dinfo.*.defaultLowOutputLatency,
            .hostApiSpecificStreamInfo = null,
        };
        if (builtin.os.tag == .windows) {
            if (ty == c.paASIO) out.suggestedLatency = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(rate));
            if (ty == c.paWASAPI and exclusive) {
                var wasapi: c.PaWasapiStreamInfo = std.mem.zeroes(c.PaWasapiStreamInfo);
                wasapi.size = @sizeOf(c.PaWasapiStreamInfo);
                wasapi.hostApiType = c.paWASAPI;
                wasapi.version = 1;
                wasapi.flags = c.paWinWasapiExclusive | c.paWinWasapiThreadPriority;
                wasapi.threadPriority = c.eThreadPriorityProAudio;
                out.hostApiSpecificStreamInfo = &wasapi;
                return e.startPaStream(&out, rate, frames);
            }
        } else if (exclusive) return false;
        return e.startPaStream(&out, rate, frames);
    }

    fn startPaStream(e: *Engine, out: *c.PaStreamParameters, rate: u32, frames: u32) bool {
        if (builtin.os.tag == .linux) unreachable;
        var stream: ?*c.PaStream = null;
        const err = c.Pa_OpenStream(&stream, null, out, @floatFromInt(rate), @min(frames, feed_max), c.paClipOff | c.paDitherOff, paCallback, e);
        if (err != c.paNoError) return false;
        e.feed_frames = @min(frames, feed_max);
        if (c.Pa_StartStream(stream) != c.paNoError) {
            _ = c.Pa_CloseStream(stream);
            return false;
        }
        e.pa_stream = stream;
        return true;
    }

    fn paCallback(_: ?*const anyopaque, out: ?*anyopaque, count: c_ulong, _: [*c]const c.PaStreamCallbackTimeInfo, flags: c.PaStreamCallbackFlags, ud: ?*anyopaque) callconv(.c) c_int {
        if (builtin.os.tag == .linux) unreachable;
        const e: *Engine = @ptrCast(@alignCast(ud));
        if ((flags & c.paOutputUnderflow) != 0) _ = e.xruns.fetchAdd(1, .monotonic);
        e.mix(@ptrCast(@alignCast(out.?)), @intCast(count));
        return c.paContinue;
    }

    // --- Mixer (audio thread only) ---

    fn startVoice(e: *Engine, sample_id: u32, loop: i32, rate: f32, gain: f32, key: u32) void {
        if (sample_id >= e.samples.len) return;
        const data = e.samples[sample_id].data;
        if (data.len < 2) return;
        const v: *Voice = if (e.active_voices < e.voices.len) blk: {
            const idx = e.active_voices;
            e.active_voices += 1;
            break :blk &e.voices[idx];
        } else blk: {
            var oldest: *Voice = &e.voices[0];
            for (e.voices[1..e.active_voices]) |*cand| {
                if (cand.age > oldest.age) oldest = cand;
            }
            break :blk oldest;
        };
        v.* = .{
            .data = data,
            .pos = 0,
            .rate = rate,
            .gain = gain,
            .loops_left = loop,
            .key = key,
        };
    }

    fn fadeInFrames(e: *const Engine) u32 {
        return @max(e.rate * 2 / 1000, 1); // ~2ms
    }

    fn fadeTailFrames(e: *const Engine) u32 {
        return @max(e.rate * 2 / 1000, 1); // ~2ms
    }

    fn fadeStopFrames(e: *const Engine) u32 {
        return @max(e.rate * 3 / 1000, 1); // ~3ms
    }

    fn requestStopVoice(e: *Engine, v: *Voice) void {
        if (v.data.len < 2) return;
        if (!e.anti_pop) {
            v.data = &.{};
            return;
        }
        if (!v.stopping) {
            v.stopping = true;
            v.stop_rem = e.fadeStopFrames();
        }
    }

    fn processCmds(e: *Engine) void {
        var t = e.cmd_tail.load(.monotonic);
        const h = e.cmd_head.load(.acquire);
        while (t != h) : (t +%= 1) {
            switch (e.cmd_buf[t % e.cmd_buf.len]) {
                .play => |p| if (!e.paused) e.startVoice(p.sample_id, p.loop, p.rate, p.gain, p.key),
                .stop_voice => |k| for (e.voices[0..e.active_voices]) |*v| {
                    if (v.key == k) e.requestStopVoice(v);
                },
                .stop_all => for (e.voices[0..e.active_voices]) |*v| {
                    e.requestStopVoice(v);
                },
                .set_paused => |p| e.paused = p,
                .set_gain => |g| e.target_gain = g,
                .set_anti_pop => |on| {
                    e.anti_pop = on;
                    e.dc_in = .{ 0, 0 };
                    e.dc_out = .{ 0, 0 };
                },
            }
        }
        e.cmd_tail.store(t, .release);
    }

    pub fn mix(e: *Engine, out: [*]f32, frames: usize) void {
        @memset(out[0 .. frames * 2], 0);
        e.processCmds();
        if (e.paused) return;

        const anti_pop = e.anti_pop;
        const fade_in_n: u32 = e.fadeInFrames();
        const fade_in_f: f32 = @floatFromInt(fade_in_n);
        const fade_tail_n: usize = e.fadeTailFrames();
        const fade_tail_f: f32 = @floatFromInt(fade_tail_n);
        const fade_stop_f: f32 = @floatFromInt(e.fadeStopFrames());
        const had_audio = e.active_voices > 0;

        var vi: usize = 0;
        while (vi < e.active_voices) {
            const v = &e.voices[vi];
            if (v.data.len < 2) {
                e.active_voices -= 1;
                e.voices[vi] = e.voices[e.active_voices];
                e.voices[e.active_voices].data = &.{};
                continue;
            }
            const total_frames = v.data.len / 2;

            // SIMD fast path: 1.0x steady-state playback strictly outside attack/tail/stop envelopes.
            if (v.rate == 1.0 and !v.stopping and v.pos >= 0) {
                const idx: usize = @intFromFloat(v.pos);
                const in_attack = anti_pop and v.age < fade_in_n;
                const safe_end = if (anti_pop and v.loops_left == 0 and total_frames > fade_tail_n)
                    total_frames - fade_tail_n
                else
                    total_frames;
                if (!in_attack and idx <= safe_end and frames <= safe_end - idx) {
                    const Vec = @Vector(8, f32);
                    const total_samples = frames * 2;
                    const src = v.data[idx * 2 .. idx * 2 + total_samples];
                    const dst = out[0..total_samples];
                    var s_i: usize = 0;
                    if (v.gain == 1.0) {
                        while (s_i + 8 <= total_samples) : (s_i += 8) {
                            const dv: Vec = dst[s_i..][0..8].*;
                            const sv: Vec = src[s_i..][0..8].*;
                            dst[s_i..][0..8].* = dv + sv;
                        }
                        while (s_i < total_samples) : (s_i += 1) dst[s_i] += src[s_i];
                    } else {
                        const gv: Vec = @splat(v.gain);
                        while (s_i + 8 <= total_samples) : (s_i += 8) {
                            const dv: Vec = dst[s_i..][0..8].*;
                            const sv: Vec = src[s_i..][0..8].*;
                            dst[s_i..][0..8].* = dv + sv * gv;
                        }
                        while (s_i < total_samples) : (s_i += 1) dst[s_i] += src[s_i] * v.gain;
                    }
                    v.pos += @floatFromInt(frames);
                    v.age +|= @intCast(frames);
                    vi += 1;
                    continue;
                }
            }

            const total_f: f64 = @floatFromInt(total_frames);
            const step: f64 = @floatCast(v.rate);

            for (0..frames) |i| {
                if (v.stopping and v.stop_rem == 0) {
                    v.data = &.{};
                    break;
                }
                if (v.pos >= total_f) {
                    if (v.loops_left == -1) {
                        v.pos = @mod(v.pos, total_f);
                    } else if (v.loops_left > 0) {
                        v.loops_left -= 1;
                        v.pos = @mod(v.pos, total_f);
                    } else {
                        v.data = &.{};
                        break;
                    }
                }

                var l: f32 = undefined;
                var r: f32 = undefined;
                if (v.rate == 1.0) {
                    const idx: usize = @intFromFloat(v.pos);
                    l = v.data[idx * 2];
                    r = v.data[idx * 2 + 1];
                } else {
                    const j: usize = @intFromFloat(v.pos);
                    const k = @min(j + 1, total_frames - 1);
                    const frac: f32 = @floatCast(v.pos - @as(f64, @floatFromInt(j)));
                    l = std.math.lerp(v.data[j * 2], v.data[k * 2], frac);
                    r = std.math.lerp(v.data[j * 2 + 1], v.data[k * 2 + 1], frac);
                }

                var env: f32 = v.gain;
                if (anti_pop) {
                    if (v.age < fade_in_n) {
                        env *= @as(f32, @floatFromInt(v.age + 1)) / fade_in_f;
                    }
                    if (v.loops_left == 0 and total_frames > fade_tail_n) {
                        const rem = total_f - v.pos;
                        if (rem < @as(f64, @floatFromInt(fade_tail_n))) {
                            env *= @as(f32, @floatCast(@max(rem, 0.0))) / fade_tail_f;
                        }
                    }
                    if (v.stopping) {
                        env *= @as(f32, @floatFromInt(v.stop_rem)) / fade_stop_f;
                        v.stop_rem -= 1;
                    }
                }

                out[i * 2] += l * env;
                out[i * 2 + 1] += r * env;
                v.pos += step;
                v.age +|= 1;
            }

            if (v.data.len < 2) {
                e.active_voices -= 1;
                e.voices[vi] = e.voices[e.active_voices];
                e.voices[e.active_voices].data = &.{};
            } else {
                vi += 1;
            }
        }

        // Skip master DSP completely during settled silence (also prevents idle DC-filter work).
        if (!had_audio and e.gain == e.target_gain and
            e.dc_in[0] == 0 and e.dc_in[1] == 0 and e.dc_out[0] == 0 and e.dc_out[1] == 0)
        {
            return;
        }

        // Smooth master gain ramp + denormal-safe 1-pole DC blocker + soft limiter
        const gain_step = 1.0 / @as(f32, @floatFromInt(@max(e.rate / 100, 1)));
        for (0..frames) |i| {
            if (anti_pop) {
                e.gain += std.math.clamp(e.target_gain - e.gain, -gain_step, gain_step);
            } else {
                e.gain = e.target_gain;
            }
            for (0..2) |ch| {
                var x = out[i * 2 + ch] * e.gain;
                if (anti_pop) {
                    var y = x - e.dc_in[ch] + 0.999 * e.dc_out[ch];
                    if (@abs(y) < 1e-18) y = 0;
                    e.dc_in[ch] = x;
                    e.dc_out[ch] = y;
                    x = y;
                }
                if (x > 1 or x < -1) {
                    const cx = std.math.clamp(x, -1.5, 1.5);
                    x = cx * (1 - cx * cx / 6.75);
                }
                out[i * 2 + ch] = x;
            }
        }
    }
};

test "engine mixes oneshot, finite loop, and stoppable infinite loop" {
    var eng: Engine = .{ .gpa = std.testing.allocator, .anti_pop = false };
    var pcm = [_]f32{ 0.5, -0.5, 0.25, -0.25 }; // 2 frames
    const samples = [_]decode.Sample{.{ .data = &pcm }};
    eng.samples = &samples;

    // Oneshot (loop = 0)
    _ = eng.play(0, 0, 1.0);
    var out: [8]f32 = undefined;
    eng.mix(&out, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[4], 1e-5);

    // Infinite loop (loop = -1) repeats across 4 frames, then stops on stopVoice
    const key = eng.play(0, -1, 1.0);
    eng.mix(&out, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[4], 1e-5);
    eng.stopVoice(key);
    eng.mix(&out, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-5);
}

test "anti-pop ramps voice attack and release smoothly without hard step" {
    var eng: Engine = .{ .gpa = std.testing.allocator, .anti_pop = true };
    var pcm: [1024]f32 = undefined; // 512 frames of 440Hz cosine (worst-case non-zero +0.8 start)
    for (0..512) |i| {
        const s: f32 = 0.8 * @cos(@as(f32, @floatFromInt(i)) * std.math.tau * 440.0 / 48000.0);
        pcm[i * 2] = s;
        pcm[i * 2 + 1] = s;
    }
    const samples = [_]decode.Sample{.{ .data = &pcm }};
    eng.samples = &samples;

    const key = eng.play(0, -1, 1.0);
    var out: [512]f32 = undefined; // 256 frames
    eng.mix(&out, 256);
    // Attack starts smoothly near 0 instead of jumping to +0.8 on frame 0
    try std.testing.expect(@abs(out[0]) < 0.05);
    var peak: f32 = 0;
    for (100..256) |i| peak = @max(peak, @abs(out[i * 2]));
    try std.testing.expect(peak > 0.6);

    // Soft stop fades out smoothly and clears the voice after fadeStopFrames (144)
    eng.stopVoice(key);
    eng.mix(&out, 256);
    try std.testing.expectEqual(@as(usize, 0), eng.voices[0].data.len);
    try std.testing.expect(@abs(out[255 * 2]) < 0.05);
}

test "mixer fast path preserves samples across steady state and transitions into tail fade" {
    var eng: Engine = .{ .gpa = std.testing.allocator, .anti_pop = true };
    var pcm: [2048]f32 = undefined; // 1024 frames
    for (0..1024) |i| {
        const s: f32 = 0.5 * @sin(@as(f32, @floatFromInt(i)) * std.math.tau * 440.0 / 48000.0);
        pcm[i * 2] = s;
        pcm[i * 2 + 1] = -s;
    }
    const samples = [_]decode.Sample{.{ .data = &pcm }};
    eng.samples = &samples;

    _ = eng.play(0, 0, 1.0);
    var out: [512]f32 = undefined; // 256 frames per block
    // Block 0: covers attack fade-in (96 frames) via slow path
    eng.mix(&out, 256);
    // Block 1 & 2 (frames 256..768): strictly inside steady-state fast path
    eng.mix(&out, 256);
    try std.testing.expectEqual(@as(f64, 512), eng.voices[0].pos);
    try std.testing.expectApproxEqAbs(pcm[511 * 2], out[255 * 2], 0.02);
    eng.mix(&out, 256);
    try std.testing.expectEqual(@as(f64, 768), eng.voices[0].pos);
    // Block 3 (frames 768..1024): enters tail fade-out and finishes cleanly
    eng.mix(&out, 256);
    try std.testing.expectEqual(@as(f64, 1024), eng.voices[0].pos);
    try std.testing.expect(@abs(out[255 * 2]) < 0.02);
    eng.mix(&out, 4);
    try std.testing.expectEqual(@as(usize, 0), eng.active_voices);
    try std.testing.expectEqual(@as(usize, 0), eng.voices[0].data.len);

    // DC blocker flushes subnormal-bound decay cleanly to exact 0
    eng.dc_out = .{ 1e-19, -1e-19 };
    eng.mix(&out, 4);
    try std.testing.expectEqual(@as(f32, 0), eng.dc_out[0]);
    try std.testing.expectEqual(@as(f32, 0), eng.dc_out[1]);
}
