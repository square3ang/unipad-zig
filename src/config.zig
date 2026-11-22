//! Persistent key=value user settings stored in SDL_GetPrefPath("unipad-zig", "unipad-zig").
const std = @import("std");
const c = @import("c");
const midi_driver = @import("midi/driver.zig");

pub const Config = struct {
    audio_device: [256]u8 = @splat(0),
    audio_device_len: usize = 0,
    audio_frames: u32 = 128,
    volume: f32 = 1.0,
    anti_pop: bool = true,

    midi_auto: bool = true,
    midi_model: midi_driver.Model = .launchpad_pro_mk3,
    midi_port: [256]u8 = @splat(0),
    midi_port_len: usize = 0,
    midi_fast_led: bool = true,

    led_enabled: bool = true,
    show_chain: bool = true,
    guide_mode: bool = false,
    speed_multiplier: f32 = 1.0,

    pub fn audioDeviceSlice(cfg: *const Config) []const u8 {
        return cfg.audio_device[0..cfg.audio_device_len];
    }

    pub fn setAudioDevice(cfg: *Config, s: []const u8) void {
        const n = @min(s.len, cfg.audio_device.len);
        @memcpy(cfg.audio_device[0..n], s[0..n]);
        cfg.audio_device_len = n;
    }

    pub fn midiPortSlice(cfg: *const Config) []const u8 {
        return cfg.midi_port[0..cfg.midi_port_len];
    }

    pub fn setMidiPort(cfg: *Config, s: []const u8) void {
        const n = @min(s.len, cfg.midi_port.len);
        @memcpy(cfg.midi_port[0..n], s[0..n]);
        cfg.midi_port_len = n;
    }
};

fn configPath(buf: []u8) ?[]const u8 {
    const pref = c.SDL_GetPrefPath("unipad-zig", "unipad-zig") orelse return null;
    defer c.SDL_free(pref);
    return std.fmt.bufPrint(buf, "{s}settings.cfg", .{std.mem.span(pref)}) catch null;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io) Config {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(&path_buf) orelse return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return .{};
    defer gpa.free(bytes);
    return parse(bytes);
}

pub fn save(io: std.Io, cfg: *const Config) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(&path_buf) orelse return;
    var out_buf: [2048]u8 = undefined;
    const data = format(&out_buf, cfg) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| {
        std.log.warn("failed to save settings ({s}): {t}", .{ path, err });
    };
}

pub fn format(buf: []u8, cfg: *const Config) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\audio_device={s}
        \\audio_frames={d}
        \\volume={d:.3}
        \\anti_pop={}
        \\midi_auto={}
        \\midi_model={s}
        \\midi_port={s}
        \\midi_fast_led={}
        \\led_enabled={}
        \\show_chain={}
        \\guide_mode={}
        \\speed_multiplier={d:.3}
        \\
    ,
        .{
            cfg.audioDeviceSlice(),
            cfg.audio_frames,
            cfg.volume,
            cfg.anti_pop,
            cfg.midi_auto,
            @tagName(cfg.midi_model),
            cfg.midiPortSlice(),
            cfg.midi_fast_led,
            cfg.led_enabled,
            cfg.show_chain,
            cfg.guide_mode,
            cfg.speed_multiplier,
        },
    );
}

pub fn parse(txt: []const u8) Config {
    var cfg: Config = .{};
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "audio_device")) {
            cfg.setAudioDevice(val);
        } else if (std.mem.eql(u8, key, "audio_frames")) {
            if (std.fmt.parseInt(u32, val, 10)) |v| cfg.audio_frames = std.math.clamp(v, 32, 4096) else |_| {}
        } else if (std.mem.eql(u8, key, "volume")) {
            if (std.fmt.parseFloat(f32, val)) |v| cfg.volume = std.math.clamp(v, 0.0, 1.5) else |_| {}
        } else if (std.mem.eql(u8, key, "anti_pop")) {
            cfg.anti_pop = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "midi_auto")) {
            cfg.midi_auto = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "midi_model")) {
            if (std.meta.stringToEnum(midi_driver.Model, val)) |m| cfg.midi_model = m;
        } else if (std.mem.eql(u8, key, "midi_port")) {
            cfg.setMidiPort(val);
        } else if (std.mem.eql(u8, key, "midi_fast_led")) {
            cfg.midi_fast_led = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "led_enabled")) {
            cfg.led_enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "show_chain")) {
            cfg.show_chain = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "guide_mode")) {
            cfg.guide_mode = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "speed_multiplier")) {
            if (std.fmt.parseFloat(f32, val)) |v| cfg.speed_multiplier = std.math.clamp(v, 0.25, 2.0) else |_| {}
        }
    }
    return cfg;
}

test "config format and parse round-trip all settings" {
    var src: Config = .{
        .audio_frames = 256,
        .volume = 0.75,
        .midi_auto = false,
        .midi_model = .launchpad_x,
        .midi_fast_led = false,
        .led_enabled = false,
        .show_chain = false,
        .guide_mode = true,
        .speed_multiplier = 1.25,
    };
    src.setAudioDevice("hw:0,0");
    src.setMidiPort("Launchpad X: Launchpad X LPX MIDI");

    var buf: [2048]u8 = undefined;
    const text = try format(&buf, &src);
    const dst = parse(text);

    try std.testing.expectEqualStrings("hw:0,0", dst.audioDeviceSlice());
    try std.testing.expectEqual(@as(u32, 256), dst.audio_frames);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), dst.volume, 1e-3);
    try std.testing.expect(!dst.midi_auto);
    try std.testing.expectEqual(midi_driver.Model.launchpad_x, dst.midi_model);
    try std.testing.expectEqualStrings("Launchpad X: Launchpad X LPX MIDI", dst.midiPortSlice());
    try std.testing.expect(!dst.midi_fast_led);
    try std.testing.expect(!dst.led_enabled);
    try std.testing.expect(!dst.show_chain);
    try std.testing.expect(dst.guide_mode);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), dst.speed_multiplier, 1e-3);
}
