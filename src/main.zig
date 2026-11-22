const std = @import("std");
const c = @import("c");
const config_mod = @import("config.zig");
const engine_mod = @import("audio/engine.zig");
const app_mod = @import("ui/app.zig");
const midi_driver = @import("midi/driver.zig");
const ableton = @import("unipack/ableton.zig");

comptime {
    _ = @import("config.zig");
    _ = @import("audio/engine.zig");
    _ = @import("unipack/palette.zig");
    _ = @import("unipack/pack.zig");
    _ = @import("unipack/ableton.zig");
    _ = @import("unipack/player.zig");
    _ = @import("midi/driver.zig");
    _ = @import("midi/backend.zig");
    _ = @import("ui/dropdown.zig");
    if (@import("builtin").os.tag == .linux) {
        _ = @import("audio/alsa.zig");
    }
}

const usage =
    \\usage: unipad-zig [pack.zip|pack.uni|project.als|dir] [options]
    \\  --convert IN OUT.zip   convert an Ableton project (.zip/.als/dir) to a UniPack .zip
    \\  --auto                 start AutoPlay immediately after loading
    \\  --null-audio           run without audio output device
    \\  --audio-device NAME    open specific ALSA (Linux) or PortAudio device
    \\  --frames N             audio period/buffer frames (default 128)
    \\  --midi-model NAME      force Launchpad model: s, mk2, pro, pro_cfw,
    \\                         corefw_rgb, corefw_s, x, mini_mk3, pro_mk3
    \\  --help                 show this message
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var pack_path: ?[]const u8 = null;
    var convert_in: ?[]const u8 = null;
    var convert_out: ?[]const u8 = null;
    var auto_start = false;
    var null_audio = false;
    var cli_audio_device: ?[]const u8 = null;
    var cli_audio_frames: ?u32 = null;
    var cli_midi_model: ?midi_driver.Model = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &buf);
            w.interface.writeAll(usage) catch {};
            w.interface.flush() catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--convert") and i + 2 < args.len) {
            convert_in = args[i + 1];
            convert_out = args[i + 2];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            auto_start = true;
        } else if (std.mem.eql(u8, arg, "--null-audio")) {
            null_audio = true;
        } else if (std.mem.eql(u8, arg, "--audio-device") and i + 1 < args.len) {
            i += 1;
            cli_audio_device = args[i];
        } else if (std.mem.eql(u8, arg, "--frames") and i + 1 < args.len) {
            i += 1;
            cli_audio_frames = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--midi-model") and i + 1 < args.len) {
            i += 1;
            cli_midi_model = parseModelFlag(args[i]);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pack_path = arg;
        }
    }

    if (convert_in != null and convert_out != null) {
        const sum = try ableton.convertToUniPackZip(gpa, io, convert_in.?, convert_out.?);
        var buf: [512]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        w.interface.print(
            "Converted Ableton project -> {s}\n  chains: {d}, sounds: {d}, led_pads: {d} ({d} events), autoPlay: {d} events\n",
            .{ convert_out.?, sum.chains, sum.sounds, sum.led_pads, sum.led_events, sum.auto_events },
        ) catch {};
        w.interface.flush() catch {};
        return;
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    var cfg = config_mod.load(gpa, io);
    if (cli_audio_device) |d| cfg.setAudioDevice(d);
    if (cli_audio_frames) |f| cfg.audio_frames = f;
    if (cli_midi_model) |m| {
        cfg.midi_model = m;
        cfg.midi_auto = false;
    }

    const win = c.SDL_CreateWindow(
        "UniPad Zig",
        1040,
        820,
        c.rb_window_flags() | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
    defer c.SDL_DestroyWindow(win);

    const engine = try engine_mod.Engine.create(gpa);
    defer engine.destroy();
    try engine.open(48000, cfg.audio_frames, null_audio, cfg.audioDeviceSlice());

    const app = try app_mod.App.init(gpa, io, win, engine, cfg);
    defer app.deinit();

    if (pack_path) |p| {
        app.loadPackPath(p);
        if (auto_start) app.player.startAutoPlay(app_mod.nowMs());
    }

    app.run();
}

fn parseModelFlag(s: []const u8) ?midi_driver.Model {
    if (std.ascii.eqlIgnoreCase(s, "s") or std.ascii.eqlIgnoreCase(s, "mini")) return .launchpad_s;
    if (std.ascii.eqlIgnoreCase(s, "mk2")) return .launchpad_mk2;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .launchpad_pro;
    if (std.ascii.eqlIgnoreCase(s, "pro_cfw") or std.ascii.eqlIgnoreCase(s, "cfw")) return .launchpad_pro_cfw;
    if (std.ascii.eqlIgnoreCase(s, "corefw_rgb") or std.ascii.eqlIgnoreCase(s, "corefw")) return .launchpad_corefw_rgb;
    if (std.ascii.eqlIgnoreCase(s, "corefw_s")) return .launchpad_corefw_s;
    if (std.ascii.eqlIgnoreCase(s, "x")) return .launchpad_x;
    if (std.ascii.eqlIgnoreCase(s, "mini_mk3")) return .launchpad_mini_mk3;
    if (std.ascii.eqlIgnoreCase(s, "pro_mk3") or std.ascii.eqlIgnoreCase(s, "mk3")) return .launchpad_pro_mk3;
    return null;
}
