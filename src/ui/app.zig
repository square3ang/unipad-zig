//! Main interactive UniPad application: virtual Launchpad, MIDI sync, and Settings drawer.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const gfx = @import("../render/gfx.zig");
const engine_mod = @import("../audio/engine.zig");
const pack_mod = @import("../unipack/pack.zig");
const ableton_mod = @import("../unipack/ableton.zig");
const player_mod = @import("../unipack/player.zig");
const midi_backend = @import("../midi/backend.zig");
const midi_driver = @import("../midi/driver.zig");
const config_mod = @import("../config.zig");
const dropdown_mod = @import("dropdown.zig");

const Color = gfx.Color;

const model_labels = blk: {
    const models = std.enums.values(midi_driver.Model);
    var out: [models.len + 1][]const u8 = undefined;
    out[0] = "Auto-Detect";
    for (models, 0..) |m, i| out[i + 1] = m.displayName();
    break :blk out;
};

const DragSlider = enum { none, volume, speed };
const DialogKind = enum { open_file, open_folder, export_zip };

const PadCoord = struct { row: u8, col: u8 };

const Layout = struct {
    frame_x: f32,
    frame_y: f32,
    frame_w: f32,
    frame_h: f32,
    cell: f32,
    gap: f32,
    grid_x: f32,
    grid_y: f32,
    rows: u8,
    cols: u8,
    show_ring: bool,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    g: gfx.Gfx,
    engine: *engine_mod.Engine,
    player: player_mod.Player,
    midi: midi_backend.Midi,

    running: bool = true,
    fullscreen: bool = false,
    settings_open: bool = false,
    nfd_ready: bool = false,
    status_msg: [256]u8 = @splat(0),
    status_len: usize = 0,
    status_until_ms: f64 = 0,

    // Active pointer pad for drag-sliding across pads
    mouse_pad: ?PadCoord = null,
    // Native file dialog (nativefiledialog-extended) async state
    dialog_lock: std.atomic.Value(bool) = .init(false),
    dialog_busy: std.atomic.Value(bool) = .init(false),
    dialog_thread: ?*c.SDL_Thread = null,
    pending_dialog_kind: DialogKind = .open_file,
    pending_open_path: ?[]u8 = null,
    last_pack_path: ?[]u8 = null,

    // Settings state
    cfg: config_mod.Config = .{},
    audio_frames: u32 = 128,
    audio_device_idx: usize = 0, // 0 = default
    volume: f32 = 1.0,
    anti_pop: bool = true,
    audio_devices: []const []const u8 = &.{},
    audio_labels: []const []const u8 = &.{},
    midi_ports: []midi_backend.PortInfo = &.{},
    midi_port_labels: []const []const u8 = &.{},
    dropdown: dropdown_mod.Dropdown = .{},
    dragging_slider: DragSlider = .none,
    ports_arena: std.heap.ArenaAllocator,
    last_midi_scan_ms: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, win: *c.SDL_Window, engine: *engine_mod.Engine, cfg: config_mod.Config) !*App {
        const a = try gpa.create(App);
        errdefer gpa.destroy(a);
        const g = try gfx.Gfx.init(gpa, win);
        a.* = .{
            .gpa = gpa,
            .io = io,
            .g = g,
            .engine = engine,
            .player = player_mod.Player.init(gpa, engine),
            .midi = midi_backend.Midi.init(gpa),
            .nfd_ready = c.NFD_Init() == c.NFD_OKAY,
            .cfg = cfg,
            .audio_frames = cfg.audio_frames,
            .volume = cfg.volume,
            .anti_pop = cfg.anti_pop,
            .ports_arena = std.heap.ArenaAllocator.init(gpa),
        };
        a.engine.setGain(cfg.volume);
        a.engine.setAntiPop(cfg.anti_pop);
        a.player.led_enabled = cfg.led_enabled;
        a.player.show_chain = cfg.show_chain;
        a.player.guide_mode = cfg.guide_mode;
        a.player.speed_multiplier = cfg.speed_multiplier;
        a.midi.auto_model = cfg.midi_auto;
        a.midi.model = cfg.midi_model;
        a.midi.fast_led_enabled = cfg.midi_fast_led;

        a.refreshDevices();
        // Match saved audio device name to dropdown index
        const saved_dev = cfg.audioDeviceSlice();
        if (saved_dev.len > 0) {
            for (a.audio_devices, 0..) |d, i| {
                if (std.mem.eql(u8, d, saved_dev)) {
                    a.audio_device_idx = i + 1;
                    break;
                }
            }
        }
        // Reconnect saved MIDI port first, otherwise auto-detect
        var connected = false;
        const saved_port = cfg.midiPortSlice();
        if (saved_port.len > 0) {
            for (a.midi_ports) |pt| {
                if (std.mem.eql(u8, pt.name, saved_port)) {
                    if (a.midi.auto_model) {
                        if (pt.detected) |det| a.midi.model = det;
                    }
                    a.midi.connect(
                        if (pt.can_read) pt.id else null,
                        if (pt.can_write) pt.id else null,
                        pt.name,
                    );
                    connected = a.midi.isConnected();
                    break;
                }
            }
        }
        if (!connected and a.midi.autoConnect(a.ports_arena.allocator())) {
            connected = true;
        }
        if (connected) {
            a.setStatus("MIDI connected: {s} ({s})", .{ a.midi.connectedLabel(), a.midi.model.displayName() });
        }
        return a;
    }

    pub fn deinit(a: *App) void {
        a.saveConfig();
        if (a.dialog_thread) |t| {
            c.SDL_WaitThread(t, null);
            a.dialog_thread = null;
        }
        if (a.pending_open_path) |p| a.gpa.free(p);
        if (a.last_pack_path) |p| a.gpa.free(p);
        if (a.nfd_ready) c.NFD_Quit();
        a.midi.sendClearLed();
        a.midi.deinit();
        a.player.deinit();
        a.ports_arena.deinit();
        a.g.deinit();
        a.gpa.destroy(a);
    }

    fn saveConfig(a: *App) void {
        const dev = if (a.audio_device_idx == 0 or a.audio_device_idx > a.audio_devices.len)
            ""
        else
            a.audio_devices[a.audio_device_idx - 1];
        a.cfg.setAudioDevice(dev);
        a.cfg.audio_frames = a.audio_frames;
        a.cfg.volume = a.volume;
        a.cfg.anti_pop = a.anti_pop;
        a.cfg.midi_auto = a.midi.auto_model;
        a.cfg.midi_model = a.midi.model;
        a.cfg.midi_fast_led = a.midi.fast_led_enabled;
        a.cfg.setMidiPort(a.midi.connectedLabel());
        a.cfg.led_enabled = a.player.led_enabled;
        a.cfg.show_chain = a.player.show_chain;
        a.cfg.guide_mode = a.player.guide_mode;
        a.cfg.speed_multiplier = a.player.speed_multiplier;
        config_mod.save(a.io, &a.cfg);
    }

    fn setStatus(a: *App, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&a.status_msg, f, args) catch return;
        a.status_len = s.len;
        a.status_until_ms = nowMs() + 4000.0;
    }

    fn refreshDevices(a: *App) void {
        a.dropdown.close();
        _ = a.ports_arena.reset(.retain_capacity);
        const pa = a.ports_arena.allocator();
        a.audio_devices = a.engine.outputDevices(pa);
        a.midi_ports = a.midi.listPorts(pa);

        if (pa.alloc([]const u8, a.audio_devices.len + 1)) |al| {
            al[0] = "System Default";
            for (a.audio_devices, 0..) |d, i| al[i + 1] = d;
            a.audio_labels = al;
        } else |_| {
            a.audio_labels = &.{};
        }
        if (a.audio_device_idx >= a.audio_labels.len) a.audio_device_idx = 0;

        if (pa.alloc([]const u8, a.midi_ports.len + 1)) |ml| {
            ml[0] = "Disconnected";
            for (a.midi_ports, 0..) |pt, i| ml[i + 1] = pt.name;
            a.midi_port_labels = ml;
        } else |_| {
            a.midi_port_labels = &.{};
        }
    }

    pub fn loadPackPath(a: *App, path: []const u8) void {
        const pk = pack_mod.load(a.gpa, a.io, path, a.engine.rate) catch |err| {
            std.log.err("failed to load UniPack \"{s}\": {t}", .{ path, err });
            a.setStatus("Load failed: {t}", .{err});
            return;
        };
        if (a.last_pack_path) |old| a.gpa.free(old);
        a.last_pack_path = a.gpa.dupe(u8, path) catch null;
        a.player.loadPack(pk);
        a.flushLedToMidi();
        if (pk.from_ableton) {
            a.setStatus("Ableton converted: {s} ({d} sounds, {d} LEDs, {d} chains)", .{ pk.title, pk.sound_count, pk.led_count, pk.chain_count });
        } else {
            a.setStatus("Loaded: {s} ({d} sounds, {d} LEDs, {d} chains)", .{ pk.title, pk.sound_count, pk.led_count, pk.chain_count });
        }
    }

    pub fn run(a: *App) void {
        while (a.running) {
            const now = nowMs();
            a.handlePendingDialog();
            a.pollEvents(now);
            a.pollMidi(now);
            a.player.smooth_guide_rgb = a.midi.useFastLed();
            a.player.tick(now);
            a.flushLedToMidi();

            // Periodically retry MIDI auto-connect if disconnected
            if (!a.midi.isConnected() and now - a.last_midi_scan_ms > 2000.0) {
                a.last_midi_scan_ms = now;
                a.refreshDevices();
                if (a.midi.autoConnect(a.ports_arena.allocator())) {
                    a.player.smooth_guide_rgb = a.midi.useFastLed();
                    a.player.pushFullLedSync();
                    a.flushLedToMidi();
                    a.setStatus("MIDI connected: {s}", .{a.midi.model.displayName()});
                }
            }

            a.draw(now);
            // Yield lightly to avoid pegging a core when vsync is off
            c.SDL_Delay(1);
        }
    }

    fn handlePendingDialog(a: *App) void {
        if (a.dialog_thread != null and !a.dialog_busy.load(.acquire)) {
            c.SDL_WaitThread(a.dialog_thread, null);
            a.dialog_thread = null;
        }
        while (a.dialog_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        const path = a.pending_open_path;
        const kind = a.pending_dialog_kind;
        a.pending_open_path = null;
        a.dialog_lock.store(false, .release);
        if (path) |p| {
            defer a.gpa.free(p);
            if (kind == .export_zip) {
                if (a.last_pack_path) |src| {
                    const sum = ableton_mod.convertToUniPackZip(a.gpa, a.io, src, p) catch |err| {
                        std.log.err("export UniPack failed: {t}", .{err});
                        a.setStatus("Export failed: {t}", .{err});
                        return;
                    };
                    a.setStatus("Exported UniPack ({d} sounds, {d} LEDs, {d} chains)", .{ sum.sounds, sum.led_pads, sum.chains });
                }
            } else {
                a.loadPackPath(p);
            }
        }
    }

    const DialogJob = struct {
        app: *App,
        kind: DialogKind,
        parent: c.nfdwindowhandle_t,
    };

    fn openNativeDialog(a: *App, kind: DialogKind) void {
        if (!a.nfd_ready) {
            a.setStatus("Native dialog unavailable", .{});
            return;
        }
        if (a.dialog_busy.swap(true, .acq_rel)) return;
        if (a.dialog_thread) |t| {
            c.SDL_WaitThread(t, null);
            a.dialog_thread = null;
        }

        var parent: c.nfdwindowhandle_t = std.mem.zeroes(c.nfdwindowhandle_t);
        _ = c.NFD_GetNativeWindowFromSDLWindow(a.g.win, &parent);
        // Wayland transient export requires wayland-scanner xdg-foreign; omit handle on Wayland so portal opens cleanly.
        if (builtin.os.tag == .linux and parent.type == c.NFD_WINDOW_HANDLE_TYPE_WAYLAND) {
            parent = std.mem.zeroes(c.nfdwindowhandle_t);
        }

        const job = a.gpa.create(DialogJob) catch {
            a.dialog_busy.store(false, .release);
            return;
        };
        job.* = .{ .app = a, .kind = kind, .parent = parent };

        if (builtin.os.tag == .macos) {
            _ = dialogWorker(job);
        } else {
            a.dialog_thread = c.SDL_CreateThread(dialogWorker, "unipad-nfd", job);
            if (a.dialog_thread == null) _ = dialogWorker(job);
        }
    }

    fn dialogWorker(ud: ?*anyopaque) callconv(.c) c_int {
        const job: *DialogJob = @ptrCast(@alignCast(ud));
        const a = job.app;
        defer {
            a.gpa.destroy(job);
            a.dialog_busy.store(false, .release);
        }

        var out_path: [*c]c.nfdu8char_t = null;
        const res: c.nfdresult_t = switch (job.kind) {
            .open_folder => blk: {
                var args: c.nfdpickfolderu8args_t = std.mem.zeroes(c.nfdpickfolderu8args_t);
                args.parentWindow = job.parent;
                args.title = "Open UniPack / Ableton Folder";
                break :blk c.NFD_PickFolderU8_With(&out_path, &args);
            },
            .open_file => blk: {
                const filters = [_]c.nfdu8filteritem_t{
                    .{ .name = "UniPack / Ableton Project", .spec = "zip,uni,als" },
                };
                var args: c.nfdopendialogu8args_t = std.mem.zeroes(c.nfdopendialogu8args_t);
                args.filterList = &filters;
                args.filterCount = filters.len;
                args.parentWindow = job.parent;
                args.title = "Open UniPack or Ableton Project";
                break :blk c.NFD_OpenDialogU8_With(&out_path, &args);
            },
            .export_zip => blk: {
                const filters = [_]c.nfdu8filteritem_t{
                    .{ .name = "UniPack Archive", .spec = "zip" },
                };
                var args: c.nfdsavedialogu8args_t = std.mem.zeroes(c.nfdsavedialogu8args_t);
                args.filterList = &filters;
                args.filterCount = filters.len;
                args.defaultName = "unipack.zip";
                args.parentWindow = job.parent;
                args.title = "Export UniPack (.zip)";
                break :blk c.NFD_SaveDialogU8_With(&out_path, &args);
            },
        };

        if (res == c.NFD_OKAY and out_path != null) {
            defer c.NFD_FreePathU8(out_path);
            const path = std.mem.span(out_path);
            if (a.gpa.dupe(u8, path)) |dup| {
                while (a.dialog_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
                if (a.pending_open_path) |old| a.gpa.free(old);
                a.pending_dialog_kind = job.kind;
                a.pending_open_path = dup;
                a.dialog_lock.store(false, .release);
            } else |_| {}
        } else if (res == c.NFD_ERROR) {
            if (c.NFD_GetError()) |err_c| {
                std.log.warn("NFD error: {s}", .{std.mem.span(err_c)});
            }
        }
        return 0;
    }

    fn modalOpen(a: *const App) bool {
        return a.settings_open;
    }

    fn pollMidi(a: *App, now: f64) void {
        var evs: [64]midi_driver.InputEvent = undefined;
        for (a.midi.poll(&evs)) |ev| {
            switch (ev) {
                .pad => |p| {
                    if (p.pressed) a.player.pressPad(p.row, p.col, now, true) else a.player.releasePad(p.row, p.col);
                },
                .chain => |ch| {
                    if (ch.pressed) a.player.setChain(ch.chain);
                },
                .function_key => {},
            }
        }
    }

    fn flushLedToMidi(a: *App) void {
        const evs = a.player.drainOutEvents();
        if (evs.len == 0) return;
        if (a.midi.connected_out != null) {
            for (evs) |ev| switch (ev) {
                .pad => |p| a.midi.sendPadLed(p.row, p.col, p.velocity, p.color),
                .ring => |r| a.midi.sendRingLed(r.idx, r.velocity, r.color),
                .clear => a.midi.queueClearLed(),
            };
            a.midi.flush();
        }
        a.player.clearOutEvents();
    }

    fn pollEvents(a: *App, now: f64) void {
        a.g.clicked = false;
        a.g.wheel = 0;
        const scale = c.SDL_GetWindowPixelDensity(a.g.win);
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => a.running = false,
                c.SDL_EVENT_DROP_FILE => {
                    if (ev.drop.data != null) a.loadPackPath(std.mem.span(ev.drop.data));
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    a.g.mx = ev.motion.x * scale;
                    a.g.my = ev.motion.y * scale;
                    if (a.g.down and !a.modalOpen()) {
                        const hit_pad = a.hitPad(a.g.mx, a.g.my);
                        if (!samePad(hit_pad, a.mouse_pad)) {
                            if (a.mouse_pad) |old| a.player.releasePad(old.row, old.col);
                            a.mouse_pad = hit_pad;
                            if (hit_pad) |p| a.player.pressPad(p.row, p.col, now, true);
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (ev.button.button == c.SDL_BUTTON_LEFT) {
                        a.g.mx = ev.button.x * scale;
                        a.g.my = ev.button.y * scale;
                        a.g.down = true;
                        a.g.clicked = true;
                        if (!a.modalOpen()) {
                            if (a.hitPad(a.g.mx, a.g.my)) |p| {
                                a.mouse_pad = p;
                                a.player.pressPad(p.row, p.col, now, true);
                            } else if (a.hitChain(a.g.mx, a.g.my)) |ch| {
                                a.player.setChain(ch);
                            }
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (ev.button.button == c.SDL_BUTTON_LEFT) {
                        a.g.down = false;
                        if (a.dragging_slider != .none) {
                            a.dragging_slider = .none;
                            a.saveConfig();
                        }
                        if (a.mouse_pad) |old| {
                            a.player.releasePad(old.row, old.col);
                            a.mouse_pad = null;
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    a.g.wheel += ev.wheel.y;
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (ev.key.repeat) continue;
                    a.handleKey(ev.key.scancode, ev.key.mod, true, now);
                },
                c.SDL_EVENT_KEY_UP => {
                    a.handleKey(ev.key.scancode, ev.key.mod, false, now);
                },
                else => {},
            }
        }
    }

    fn handleKey(a: *App, sc: c.SDL_Scancode, mod: c.SDL_Keymod, down: bool, now: f64) void {
        if (a.dropdown.isOpen()) {
            if (down) {
                const target = a.dropdown.target;
                if (a.dropdown.handleKey(sc)) |idx| a.applyDropdownChoice(target, idx);
            }
            return;
        }
        if (down) {
            switch (sc) {
                c.SDL_SCANCODE_ESCAPE => {
                    if (a.settings_open) {
                        a.settings_open = false;
                        a.dropdown.close();
                    } else {
                        a.running = false;
                    }
                    return;
                },
                c.SDL_SCANCODE_O => {
                    const shift = (mod & c.SDL_KMOD_SHIFT) != 0;
                    a.openNativeDialog(if (shift) .open_folder else .open_file);
                    return;
                },
                c.SDL_SCANCODE_TAB => {
                    a.settings_open = !a.settings_open;
                    a.dropdown.close();
                    if (a.settings_open) a.refreshDevices();
                    return;
                },
                c.SDL_SCANCODE_F11 => {
                    a.fullscreen = !a.fullscreen;
                    _ = c.SDL_SetWindowFullscreen(a.g.win, a.fullscreen);
                    return;
                },
                c.SDL_SCANCODE_SPACE => {
                    if (a.player.auto_playing) a.player.stopAutoPlay() else a.player.startAutoPlay(now);
                    return;
                },
                c.SDL_SCANCODE_P => {
                    if (a.player.practice_playing) a.player.stopPractice() else a.player.startPractice(now);
                    return;
                },
                c.SDL_SCANCODE_BACKSPACE => {
                    a.player.clearLeds();
                    return;
                },
                c.SDL_SCANCODE_F1...c.SDL_SCANCODE_F8 => {
                    a.player.setChain(@intCast(sc - c.SDL_SCANCODE_F1));
                    return;
                },
                else => {},
            }
        }
        if (a.settings_open) return;

        // 4x8 QWERTY grid mapping for quick keyboard play
        const key_pad: ?PadCoord = switch (sc) {
            c.SDL_SCANCODE_1 => .{ .row = 0, .col = 0 },
            c.SDL_SCANCODE_2 => .{ .row = 0, .col = 1 },
            c.SDL_SCANCODE_3 => .{ .row = 0, .col = 2 },
            c.SDL_SCANCODE_4 => .{ .row = 0, .col = 3 },
            c.SDL_SCANCODE_5 => .{ .row = 0, .col = 4 },
            c.SDL_SCANCODE_6 => .{ .row = 0, .col = 5 },
            c.SDL_SCANCODE_7 => .{ .row = 0, .col = 6 },
            c.SDL_SCANCODE_8 => .{ .row = 0, .col = 7 },
            c.SDL_SCANCODE_Q => .{ .row = 1, .col = 0 },
            c.SDL_SCANCODE_W => .{ .row = 1, .col = 1 },
            c.SDL_SCANCODE_E => .{ .row = 1, .col = 2 },
            c.SDL_SCANCODE_R => .{ .row = 1, .col = 3 },
            c.SDL_SCANCODE_T => .{ .row = 1, .col = 4 },
            c.SDL_SCANCODE_Y => .{ .row = 1, .col = 5 },
            c.SDL_SCANCODE_U => .{ .row = 1, .col = 6 },
            c.SDL_SCANCODE_I => .{ .row = 1, .col = 7 },
            c.SDL_SCANCODE_A => .{ .row = 2, .col = 0 },
            c.SDL_SCANCODE_S => .{ .row = 2, .col = 1 },
            c.SDL_SCANCODE_D => .{ .row = 2, .col = 2 },
            c.SDL_SCANCODE_F => .{ .row = 2, .col = 3 },
            c.SDL_SCANCODE_G => .{ .row = 2, .col = 4 },
            c.SDL_SCANCODE_H => .{ .row = 2, .col = 5 },
            c.SDL_SCANCODE_J => .{ .row = 2, .col = 6 },
            c.SDL_SCANCODE_K => .{ .row = 2, .col = 7 },
            c.SDL_SCANCODE_Z => .{ .row = 3, .col = 0 },
            c.SDL_SCANCODE_X => .{ .row = 3, .col = 1 },
            c.SDL_SCANCODE_C => .{ .row = 3, .col = 2 },
            c.SDL_SCANCODE_V => .{ .row = 3, .col = 3 },
            c.SDL_SCANCODE_B => .{ .row = 3, .col = 4 },
            c.SDL_SCANCODE_N => .{ .row = 3, .col = 5 },
            c.SDL_SCANCODE_M => .{ .row = 3, .col = 6 },
            c.SDL_SCANCODE_COMMA => .{ .row = 3, .col = 7 },
            else => null,
        };
        if (key_pad) |p| {
            if (down) a.player.pressPad(p.row, p.col, now, true) else a.player.releasePad(p.row, p.col);
        }
    }

    fn computeLayout(a: *const App) Layout {
        const rows: u8 = if (a.player.pack) |pk| pk.button_x else 8;
        const cols: u8 = if (a.player.pack) |pk| pk.button_y else 8;
        const show_ring = rows == 8 and cols == 8;
        const total_r: f32 = @floatFromInt(if (show_ring) rows + 2 else rows);
        const total_c: f32 = @floatFromInt(if (show_ring) cols + 2 else cols);

        const top_bar_h: f32 = 64;
        const footer_h: f32 = 36;
        const pad_margin: f32 = 24;
        const avail_w = @max(a.g.w - pad_margin * 2, 160);
        const avail_h = @max(a.g.h - top_bar_h - footer_h - pad_margin * 2, 160);
        const unit = @min(avail_w / total_c, avail_h / total_r);
        const gap = @max(unit * 0.11, 3.0);
        const cell = unit - gap;
        const frame_pad = unit * 0.32;
        const inner_w = total_c * cell + (total_c - 1) * gap;
        const inner_h = total_r * cell + (total_r - 1) * gap;
        const frame_w = inner_w + frame_pad * 2;
        const frame_h = inner_h + frame_pad * 2;
        const frame_x = (a.g.w - frame_w) / 2;
        const frame_y = top_bar_h + (a.g.h - top_bar_h - footer_h - frame_h) / 2;
        const offset: f32 = if (show_ring) cell + gap else 0;
        return .{
            .frame_x = frame_x,
            .frame_y = frame_y,
            .frame_w = frame_w,
            .frame_h = frame_h,
            .cell = cell,
            .gap = gap,
            .grid_x = frame_x + frame_pad + offset,
            .grid_y = frame_y + frame_pad + offset,
            .rows = rows,
            .cols = cols,
            .show_ring = show_ring,
        };
    }

    fn hitPad(a: *const App, mx: f32, my: f32) ?PadCoord {
        const l = a.computeLayout();
        const step = l.cell + l.gap;
        const rx = mx - l.grid_x;
        const ry = my - l.grid_y;
        if (rx < 0 or ry < 0) return null;
        const col_i: i32 = @intFromFloat(@floor(rx / step));
        const row_i: i32 = @intFromFloat(@floor(ry / step));
        if (row_i < 0 or row_i >= l.rows or col_i < 0 or col_i >= l.cols) return null;
        const fx = rx - @as(f32, @floatFromInt(col_i)) * step;
        const fy = ry - @as(f32, @floatFromInt(row_i)) * step;
        if (fx > l.cell or fy > l.cell) return null;
        return .{ .row = @intCast(row_i), .col = @intCast(col_i) };
    }

    fn hitChain(a: *const App, mx: f32, my: f32) ?u8 {
        const l = a.computeLayout();
        if (!l.show_ring) return null;
        const step = l.cell + l.gap;
        const chains: u8 = if (a.player.pack) |pk| pk.chain_count else 8;
        for (0..@min(chains, 24)) |ci| {
            const pos = ringCellPos(l, @intCast(ci + 8));
            if (mx >= pos[0] and mx <= pos[0] + l.cell and my >= pos[1] and my <= pos[1] + l.cell) {
                return @intCast(ci);
            }
        }
        _ = step;
        return null;
    }

    fn ringCellPos(l: Layout, ring_idx: u8) [2]f32 {
        const step = l.cell + l.gap;
        if (ring_idx < 8) {
            return .{ l.grid_x + @as(f32, @floatFromInt(ring_idx)) * step, l.grid_y - step }; // Top 0..7
        } else if (ring_idx < 16) {
            return .{ l.grid_x + 8 * step, l.grid_y + @as(f32, @floatFromInt(ring_idx - 8)) * step }; // Right 8..15
        } else if (ring_idx < 24) {
            const k = ring_idx - 16;
            return .{ l.grid_x + @as(f32, @floatFromInt(7 - k)) * step, l.grid_y + 8 * step }; // Bottom 16..23 (R->L)
        } else if (ring_idx < 32) {
            const k = ring_idx - 24;
            return .{ l.grid_x - step, l.grid_y + @as(f32, @floatFromInt(7 - k)) * step }; // Left 24..31 (B->T)
        } else {
            return .{ l.grid_x + 8 * step, l.grid_y - step }; // Logo (top-right)
        }
    }

    fn draw(a: *App, now: f64) void {
        a.g.beginFrame();
        a.g.vgrad(0, 0, a.g.w, a.g.h, gfx.bg, gfx.bg_bottom);
        a.drawHeader(now);
        a.drawLaunchpad();
        a.drawFooter(now);
        if (a.settings_open) a.drawSettings();
        a.g.present();
    }

    fn drawHeader(a: *App, now: f64) void {
        const g = &a.g;
        const bar_h: f32 = 64;
        g.vgrad(0, 0, g.w, bar_h, .{ .r = 22, .g = 26, .b = 38 }, gfx.surface);
        g.rect(0, bar_h - 1, g.w, 1, gfx.border_col);

        // Brand / Pack accent badge
        const has_pack = a.player.pack != null;
        g.round(16, 15, 5, 34, 2.5, if (has_pack) gfx.accent else gfx.border_col);

        const title = if (a.player.pack) |pk| pk.title else "UniPad Zig";
        const sub = if (a.player.pack) |pk|
            (if (pk.producer.len > 0) pk.producer else "Loaded UniPack")
        else
            "Drop .zip / .uni / .als or click Open";
        g.textClip(title, 30, 12, g.w * 0.30, 18, gfx.white);
        g.textClip(sub, 30, 36, g.w * 0.30, 12, gfx.dim);

        // Right-aligned toolbar controls
        var rx: f32 = g.w - 16;
        const by: f32 = 15;
        const bh: f32 = 34;

        // Settings button
        rx -= 88;
        if (a.button(rx, by, 88, bh, if (a.settings_open) "Close" else "Settings", a.settings_open)) {
            a.settings_open = !a.settings_open;
            a.dropdown.close();
            if (a.settings_open) a.refreshDevices();
        }
        rx -= 10;

        // Playback group: Clear LED + AutoPlay
        rx -= 84;
        if (a.button(rx, by, 84, bh, "Clear LED", false)) {
            a.player.clearLeds();
        }
        rx -= 6;

        const has_auto = if (a.player.pack) |pk| pk.auto_play.len > 0 else false;
        rx -= 88;
        if (a.button(rx, by, 88, bh, if (a.player.practice_playing) "Stop Prac" else "Practice", a.player.practice_playing)) {
            if (has_auto) {
                if (a.player.practice_playing) a.player.stopPractice() else a.player.startPractice(now);
            } else {
                a.setStatus("No autoPlay file in pack", .{});
            }
        }
        rx -= 6;

        rx -= 92;
        if (a.button(rx, by, 92, bh, if (a.player.auto_playing) "Stop Auto" else "AutoPlay", a.player.auto_playing)) {
            if (has_auto) {
                if (a.player.auto_playing) a.player.stopAutoPlay() else a.player.startAutoPlay(now);
            } else {
                a.setStatus("No autoPlay file in pack", .{});
            }
        }
        rx -= 12;

        // File group: Folder + Open (+ Export when Ableton project loaded)
        rx -= 74;
        if (a.button(rx, by, 74, bh, "Folder", false)) {
            a.openNativeDialog(.open_folder);
        }
        rx -= 6;

        rx -= 72;
        if (a.button(rx, by, 72, bh, "Open", false)) {
            a.openNativeDialog(.open_file);
        }
        rx -= 6;

        const is_ableton = if (a.player.pack) |pk| pk.from_ableton else false;
        if (is_ableton and a.last_pack_path != null) {
            rx -= 78;
            if (a.button(rx, by, 78, bh, "Export", false)) {
                a.openNativeDialog(.export_zip);
            }
            rx -= 6;
        }
        rx -= 6;

        // MIDI status pill (opens Settings on click)
        const midi_w: f32 = 156;
        rx -= midi_w;
        const connected = a.midi.isConnected();
        const midi_hover = !a.settings_open and g.hit(rx, by, midi_w, bh);
        g.roundBox(rx, by, midi_w, bh, 8, if (midi_hover) gfx.panel_col else gfx.card, if (connected) gfx.good.alpha(120) else gfx.border_col);
        if (connected) {
            g.additive(true);
            g.disc(rx + 15, by + bh / 2, 7.5, gfx.good.alpha(70));
            g.additive(false);
        }
        g.disc(rx + 15, by + bh / 2, 4.0, if (connected) gfx.good else gfx.dim);
        const midi_txt = if (connected) a.midi.model.displayName() else "No Launchpad";
        g.textClip(midi_txt, rx + 27, by + 10, midi_w - 35, 12, if (connected) gfx.white else gfx.dim);
        if (g.clickIn(rx, by, midi_w, bh)) {
            a.settings_open = true;
            a.dropdown.close();
            a.refreshDevices();
        }

        // AutoPlay / Practice Mode progress bar along header bottom
        if (a.player.auto_playing) {
            const prog = a.player.autoProgress();
            g.rect(0, bar_h - 3, g.w * prog, 3, gfx.accent);
        } else if (a.player.practice_playing) {
            const prog = a.player.practiceProgress();
            g.rect(0, bar_h - 3, g.w * prog, 3, if (a.player.practice_paused_chain != null) gfx.warn else gfx.good);
        }
    }

    fn drawLaunchpad(a: *App) void {
        const g = &a.g;
        const l = a.computeLayout();
        const step = l.cell + l.gap;

        // Ambient soft drop shadow behind hardware body
        g.round(l.frame_x - 6, l.frame_y + 10, l.frame_w + 12, l.frame_h + 10, 26, .{ .r = 0, .g = 0, .b = 0, .a = 115 });
        g.round(l.frame_x - 2, l.frame_y + 4, l.frame_w + 4, l.frame_h + 4, 22, .{ .r = 0, .g = 0, .b = 0, .a = 95 });

        // Outer matte aluminum chassis + top specular lip
        g.roundBox(l.frame_x, l.frame_y, l.frame_w, l.frame_h, 20, .{ .r = 20, .g = 22, .b = 29 }, .{ .r = 50, .g = 56, .b = 74 });
        g.rect(l.frame_x + 22, l.frame_y + 1, l.frame_w - 44, 1, .{ .r = 92, .g = 102, .b = 128, .a = 90 });

        // Recessed inner pad deck well
        const well_inset: f32 = 8;
        g.roundBox(
            l.frame_x + well_inset,
            l.frame_y + well_inset,
            l.frame_w - well_inset * 2,
            l.frame_h - well_inset * 2,
            14,
            .{ .r = 11, .g = 12, .b = 16 },
            .{ .r = 30, .g = 34, .b = 44 },
        );

        // Draw Ring & Logo LEDs (when 8x8) — Launchpad Pro Mk3 flat matte caps, backlit legends only
        if (l.show_ring) {
            const chain_count: u8 = if (a.player.pack) |pk| pk.chain_count else 8;
            const ring_r = l.cell * 0.08;
            const top_labels = [6][]const u8{ "Session", "Note", "Chord", "Custom", "Sequencer", "Projects" };
            const bot_labels = [8][2][]const u8{
                .{ "Record", "Arm" }, .{ "Mute", "" },  .{ "Solo", "" },   .{ "Volume", "" },
                .{ "Pan", "" },       .{ "Sends", "" }, .{ "Device", "" }, .{ "Stop", "Clip" },
            };
            const left_labels = [4][2][]const u8{
                .{ "Clear", "" }, .{ "Duplicate", "" }, .{ "Quantise", "" }, .{ "Fixed", "Length" },
            };
            const short_sz: u16 = if (l.cell >= 92) 18 else if (l.cell >= 72) 16 else if (l.cell >= 54) 14 else 12;
            const long_sz: u16 = if (l.cell >= 104) 18 else if (l.cell >= 84) 16 else if (l.cell >= 66) 14 else 12;
            const tri_sz = @max(l.cell * 0.25, 10.0);

            for (0..32) |i| {
                const idx: u8 = @intCast(i);
                const pos = ringCellPos(l, idx);
                const cx = pos[0] + l.cell / 2;
                const cy = pos[1] + l.cell / 2;
                const led = a.player.ring_leds[idx];
                const is_chain = idx >= 8 and (idx - 8) < chain_count;
                const is_active_chain = is_chain and (idx - 8) == a.player.current_chain;
                const is_guide_chain = is_chain and a.player.isGuideChain(idx - 8);
                const hover = is_chain and !a.modalOpen() and g.hit(pos[0], pos[1], l.cell, l.cell);
                const led_lit = led.velocity != 0 or (led.color & 0x00FFFFFF) != 0;
                const lit = led_lit or is_guide_chain;
                const cap_col: Color = if (hover) .{ .r = 34, .g = 38, .b = 50 } else .{ .r = 24, .g = 27, .b = 35 };
                const legend_col: Color = if (is_guide_chain)
                    gfx.white
                else if (led_lit)
                    ledColor(led.color)
                else if (hover)
                    .{ .r = 180, .g = 188, .b = 204 }
                else
                    .{ .r = 112, .g = 118, .b = 132 };
                const cap_stroke: Color = if (lit)
                    legend_col
                else if (hover)
                    .{ .r = 90, .g = 100, .b = 122 }
                else
                    .{ .r = 56, .g = 62, .b = 76 };

                // Opaque matte cap; LED lights both the thicker outline and the legend/text
                g.roundBoxThick(pos[0], pos[1], l.cell, l.cell, ring_r, @max(l.cell * 0.042, 2.2), cap_col, cap_stroke);

                if (idx < 8) {
                    if (idx == 0) {
                        g.triDir(cx, cy, tri_sz, .left, legend_col);
                    } else if (idx == 1) {
                        g.triDir(cx, cy, tri_sz, .right, legend_col);
                    } else {
                        const lbl = top_labels[idx - 2];
                        g.textCentered(lbl, cx, cy, if (lbl.len >= 7) long_sz else short_sz, legend_col);
                    }
                } else if (idx < 16) {
                    g.chevron(cx, cy, l.cell * 0.21, l.cell * 0.32, @max(l.cell * 0.045, 2.0), .right, legend_col);
                } else if (idx < 24) {
                    const pair = bot_labels[23 - idx];
                    const sz = if (pair[0].len >= 7 or pair[1].len >= 7) long_sz else short_sz;
                    if (pair[1].len == 0) {
                        g.textCentered(pair[0], cx, cy, sz, legend_col);
                    } else {
                        const dy: f32 = @as(f32, @floatFromInt(sz)) * 0.56;
                        g.textCentered(pair[0], cx, cy - dy, sz, legend_col);
                        g.textCentered(pair[1], cx, cy + dy, sz, legend_col);
                    }
                } else {
                    const row_idx = 31 - idx; // 0 (top) .. 7 (bottom)
                    if (row_idx == 0) {
                        g.triDir(cx, cy, tri_sz, .up, legend_col);
                    } else if (row_idx == 1) {
                        g.triDir(cx, cy, tri_sz, .down, legend_col);
                    } else if (row_idx < 6) {
                        const pair = left_labels[row_idx - 2];
                        const sz = if (pair[0].len >= 7 or pair[1].len >= 7) long_sz else short_sz;
                        if (pair[1].len == 0) {
                            g.textCentered(pair[0], cx, cy, sz, legend_col);
                        } else {
                            const dy: f32 = @as(f32, @floatFromInt(sz)) * 0.56;
                            g.textCentered(pair[0], cx, cy - dy, sz, legend_col);
                            g.textCentered(pair[1], cx, cy + dy, sz, legend_col);
                        }
                    } else if (row_idx == 6) {
                        const play_sz = @max(l.cell * 0.31, 12.0);
                        g.triDir(cx, cy, play_sz, .right, legend_col);
                        g.triDir(cx - play_sz * 0.04, cy, play_sz * 0.62, .right, cap_col);
                    } else {
                        g.ring(cx, cy, @max(l.cell * 0.16, 6.5), @max(l.cell * 0.04, 2.0), legend_col);
                    }
                }

                // Side pointer arrow outside frame pointing inward at the active chain (Web UniPad style)
                if (is_active_chain) {
                    const arrow_col: Color = .{ .r = 186, .g = 194, .b = 212 };
                    const aw = @max(l.cell * 0.16, 7.0);
                    const ah = @max(l.cell * 0.24, 11.0);
                    const at = @max(l.cell * 0.04, 2.0);
                    if (idx < 16) {
                        g.chevron(l.frame_x + l.frame_w + 13, cy, aw, ah, at, .left, arrow_col);
                    } else if (idx < 24) {
                        g.chevron(cx, l.frame_y + l.frame_h + 13, ah, aw, at, .up, arrow_col);
                    } else {
                        g.chevron(l.frame_x - 13, cy, aw, ah, at, .right, arrow_col);
                    }
                }
            }

            // Novation Logo indicator (top-right, flush in chassis — not a button)
            const logo_pos = ringCellPos(l, pack_mod.logo_led_index);
            const logo_led = a.player.ring_leds[pack_mod.logo_led_index];
            const logo_lit = logo_led.velocity != 0 or (logo_led.color & 0x00FFFFFF) != 0;
            const logo_col: Color = if (logo_lit) ledColor(logo_led.color) else .{ .r = 74, .g = 78, .b = 90 };
            const lcx = logo_pos[0] + l.cell / 2;
            const lcy = logo_pos[1] + l.cell / 2;
            const l_in = l.cell * 0.16;
            const l_sz = l.cell - l_in * 2;
            const well_dark: Color = .{ .r = 11, .g = 12, .b = 16 };
            g.round(logo_pos[0] + l_in, logo_pos[1] + l_in, l_sz, l_sz, l_sz * 0.14, logo_col);
            const d = l_sz * 0.42;
            g.diamond(lcx, lcy, d, d, well_dark);
            const sp = d * 0.62;
            const t = @max(l_sz * 0.055, 1.8);
            g.quad(
                .{ lcx - sp - t, lcy + sp - t },
                .{ lcx + sp - t, lcy - sp - t },
                .{ lcx + sp + t, lcy - sp + t },
                .{ lcx - sp + t, lcy + sp + t },
                logo_col,
            );
        }

        // Draw Pad Grid
        for (0..l.rows) |r_usize| {
            const r: u8 = @intCast(r_usize);
            for (0..l.cols) |c_usize| {
                const col_i: u8 = @intCast(c_usize);
                const px = l.grid_x + @as(f32, @floatFromInt(col_i)) * step;
                const py = l.grid_y + @as(f32, @floatFromInt(r)) * step;
                const idx = @as(usize, r) * pack_mod.max_grid + col_i;
                const led = a.player.pad_leds[idx];
                const pressed = a.player.pad_pressed[idx];
                const guide_lvl = a.player.guidePadLevel(r, col_i);
                const is_guide_pad = guide_lvl > 0.0;
                const is_guide_now = guide_lvl >= 0.30;
                const led_lit = led.velocity != 0 or (led.color & 0x00FFFFFF) != 0;
                const lit = led_lit or is_guide_now;

                const idle_col: Color = .{ .r = 80, .g = 80, .b = 80 };
                const guide_col = if (is_guide_now)
                    gfx.mix(idle_col, gfx.white, std.math.clamp((guide_lvl - 0.25) / 0.75, 0.25, 1.0))
                else
                    gfx.mix(idle_col, gfx.accent, 0.22);
                const base_col: Color = if (led_lit)
                    ledColor(led.color)
                else if (is_guide_pad)
                    guide_col
                else if (pressed)
                    .{ .r = 120, .g = 120, .b = 128 }
                else
                    idle_col;

                const corner: u8 = if (l.rows == 8 and l.cols == 8) blk: {
                    if (r == 3 and col_i == 3) break :blk 1; // BR
                    if (r == 3 and col_i == 4) break :blk 2; // BL
                    if (r == 4 and col_i == 3) break :blk 3; // TR
                    if (r == 4 and col_i == 4) break :blk 4; // TL
                    break :blk 0;
                } else 0;

                // Two-stage LED bloom for lit pads (no bloom on dim next-step preview)
                if (lit) {
                    const bloom_a: u8 = if (!led_lit and is_guide_now) @intFromFloat(@round(70.0 * guide_lvl * guide_lvl)) else 70;
                    if (bloom_a > 2) {
                        g.additive(true);
                        g.round(px - l.gap * 0.55, py - l.gap * 0.55, l.cell + l.gap * 1.1, l.cell + l.gap * 1.1, l.cell * 0.22, base_col.alpha(bloom_a));
                        g.additive(false);
                    }
                }

                // Dark recessed socket border
                const inset: f32 = if (pressed) 1.8 else 0;
                g.chamferPad(px + inset, py + inset, l.cell - inset * 2, l.cell - inset * 2, l.cell * 0.23, corner, .{ .r = 16, .g = 18, .b = 24 });

                // Silicone pad face
                const face_in = inset + 1.2;
                const face_s = l.cell - face_in * 2;
                g.chamferPad(px + face_in, py + face_in, face_s, face_s, l.cell * 0.22, corner, base_col);

                if (lit) {
                    // Diffused hot core inside LED silicone
                    const core_in = face_in + face_s * 0.16;
                    const core_s = face_s * 0.68;
                    const core_a: u8 = if (!led_lit and is_guide_now) @intFromFloat(@round(145.0 * guide_lvl * guide_lvl)) else 145;
                    if (core_a > 4) {
                        g.round(px + core_in, py + core_in, core_s, core_s, core_s * 0.24, gfx.mix(base_col, gfx.white, 0.34).alpha(core_a));
                    }
                } else {
                    // Subtle matte top sheen on unlit silicone
                    g.rect(px + face_in + 4, py + face_in + 1, @max(face_s - 8, 2), 1.2, .{ .r = 255, .g = 255, .b = 255, .a = 28 });
                }

                if (pressed) {
                    g.rectOutline(px + inset, py + inset, l.cell - inset * 2, l.cell - inset * 2, 2.0, gfx.white.alpha(180));
                }

                // Distinct guide indicator: bold white ring for Press NOW vs subtle cyan ring for Next preview
                if (is_guide_now) {
                    const ring_r = l.cell * (0.38 - 0.08 * guide_lvl);
                    const ring_w = 2.0 + 1.4 * guide_lvl;
                    g.ring(px + l.cell / 2, py + l.cell / 2, ring_r, ring_w, gfx.white);
                } else if (is_guide_pad) {
                    g.ring(px + l.cell / 2, py + l.cell / 2, l.cell * 0.36, 1.8, gfx.accent.alpha(185));
                }
            }
        }

        // Subtle center diamond emblem framed by the 4 chamfered center pads
        if (l.rows == 8 and l.cols == 8) {
            const dcx = l.grid_x + 4 * step - l.gap / 2;
            const dcy = l.grid_y + 4 * step - l.gap / 2;
            g.diamond(dcx, dcy, l.cell * 0.13, l.cell * 0.13, .{ .r = 46, .g = 52, .b = 68 });
            g.diamond(dcx, dcy, l.cell * 0.07, l.cell * 0.07, gfx.accent.alpha(140));
        }
    }

    fn drawFooter(a: *App, now: f64) void {
        const g = &a.g;
        const fy = g.h - 34;
        g.rect(0, fy, g.w, 34, gfx.surface);
        g.rect(0, fy, g.w, 1, gfx.border_col);

        const chain_count: u8 = if (a.player.pack) |pk| pk.chain_count else 1;
        var fx: f32 = 14;
        // Chain badge
        g.roundBox(fx, fy + 6, 86, 22, 6, gfx.card, gfx.border_col);
        g.fmtCentered(fx + 43, fy + 17, 12, gfx.white, "CH {d}/{d}", .{ a.player.current_chain + 1, chain_count });
        fx += 94;

        // Speed badge
        g.roundBox(fx, fy + 6, 76, 22, 6, gfx.card, gfx.border_col);
        g.fmtCentered(fx + 38, fy + 17, 12, gfx.dim, "{d:.2}x", .{a.player.speed_multiplier});
        fx += 84;

        // Audio badge
        const dev_txt = if (a.engine.is_null) "Null" else if (a.engine.device.len > 0) a.engine.device else "Default";
        const xr = a.engine.xruns.load(.monotonic);
        if (xr > 0) {
            g.fmt(fx, fy + 9, 12, gfx.warn, "Audio: {s} ({d}f, {d} xrun)", .{ dev_txt, a.engine.feed_frames, xr });
        } else {
            g.fmt(fx, fy + 9, 12, gfx.dim, "Audio: {s} ({d}f)", .{ dev_txt, a.engine.feed_frames });
        }

        if (a.status_len > 0 and now < a.status_until_ms) {
            const s = a.status_msg[0..a.status_len];
            g.textRight(s, g.w - 16, fy + 9, 12, gfx.white);
        } else {
            if (a.player.practice_playing) {
                if (a.player.practice_paused_chain) |pch| {
                    var pbuf: [80]u8 = undefined;
                    const ptxt = std.fmt.bufPrint(&pbuf, "Practice paused - switch to Chain {d} to continue", .{pch + 1}) catch "Practice paused";
                    g.textRight(ptxt, g.w - 16, fy + 9, 12, gfx.warn);
                } else {
                    g.textRight("Practice Mode active   P: Stop   Space: AutoPlay", g.w - 16, fy + 9, 12, gfx.good);
                }
            } else {
                g.textRight("O: Open   Space: AutoPlay   P: Practice   Tab: Settings", g.w - 16, fy + 9, 12, gfx.dim);
            }
        }
    }

    fn drawSettings(a: *App) void {
        const g = &a.g;
        const drop_open = a.dropdown.isOpen();
        // Hold clicks back from underlying controls while a dropdown popup is open.
        const saved_click = g.clicked;
        if (drop_open) g.clicked = false;

        g.rect(0, 64, g.w, g.h - 64, .{ .r = 0, .g = 0, .b = 0, .a = 175 });

        const pw: f32 = @min(600, g.w - 40);
        const ph: f32 = @min(596, g.h - 92);
        const px = (g.w - pw) / 2;
        const py = 64 + (g.h - 64 - ph) / 2;

        // Sheet shadow + body
        g.round(px - 6, py + 8, pw + 12, ph + 8, 20, .{ .r = 0, .g = 0, .b = 0, .a = 120 });
        g.roundBox(px, py, pw, ph, 16, gfx.surface, gfx.border_col);

        // Modal header
        g.text("Settings", px + 24, py + 18, 20, gfx.white);
        if (a.button(px + pw - 86, py + 14, 66, 30, "Done", false)) {
            a.settings_open = false;
            a.dropdown.close();
            return;
        }
        g.rect(px + 20, py + 54, pw - 40, 1, gfx.border_col.alpha(140));

        const lx = px + 20;
        const cw = pw - 40;
        var y = py + 66;

        // === Card 1: MIDI Launchpad ===
        const midi_card_h: f32 = 166;
        g.roundBox(lx, y, cw, midi_card_h, 12, gfx.card, gfx.border_col.alpha(130));
        g.text("MIDI LAUNCHPAD", lx + 16, y + 12, 12, gfx.accent);
        const midi_badge_col = if (a.midi.isConnected()) gfx.good else gfx.dim;
        g.disc(lx + cw - 92, y + 19, 3.5, midi_badge_col);
        g.text(if (a.midi.isConnected()) "Connected" else "Standby", lx + cw - 82, y + 12, 12, midi_badge_col);

        const field_x = lx + 104;
        const field_w = cw - 208;

        // Row 1: Launchpad Model Dropdown + Send Init
        const r1y = y + 40;
        g.text("Model", lx + 16, r1y + 8, 14, gfx.dim);
        const model_idx: usize = if (a.midi.auto_model) 0 else @intFromEnum(a.midi.model) + 1;
        var model_disp_buf: [64]u8 = undefined;
        const model_disp = if (a.midi.auto_model)
            (std.fmt.bufPrint(&model_disp_buf, "Auto ({s})", .{a.midi.model.displayName()}) catch "Auto-Detect")
        else
            a.midi.model.displayName();
        if (a.dropdown.trigger(g, .midi_model, field_x, r1y, field_w, 34, model_disp, !drop_open)) {
            a.dropdown.show(.midi_model, &model_labels, model_idx);
        }
        if (a.button(field_x + field_w + 8, r1y, 80, 34, "Send Init", false)) {
            a.midi.sendInit();
            a.player.pushFullLedSync();
            a.flushLedToMidi();
            a.setStatus("Sent init SysEx ({s})", .{a.midi.model.displayName()});
        }

        // Row 2: MIDI Port Dropdown + Refresh
        const r2y = y + 82;
        g.text("Port", lx + 16, r2y + 8, 14, gfx.dim);
        const cur_port_idx = a.currentMidiPortIndex();
        const cur_port_label = if (cur_port_idx < a.midi_port_labels.len) a.midi_port_labels[cur_port_idx] else "Disconnected";
        if (a.dropdown.trigger(g, .midi_port, field_x, r2y, field_w, 34, cur_port_label, !drop_open)) {
            a.dropdown.show(.midi_port, a.midi_port_labels, cur_port_idx);
        }
        if (a.button(field_x + field_w + 8, r2y, 80, 34, "Refresh", false)) {
            a.refreshDevices();
            a.setStatus("Found {d} MIDI port(s)", .{a.midi_ports.len});
        }

        // Row 3: FastLED toggle (CoreFW / Pro CFW 0xF0 0x5F RGB SysEx)
        const r3y = y + 124;
        g.text("FastLED", lx + 16, r3y + 7, 14, gfx.dim);
        if (a.pillToggle(field_x, r3y, 128, 32, "FastLED", a.midi.fast_led_enabled)) {
            a.midi.setFastLedEnabled(!a.midi.fast_led_enabled);
            a.player.smooth_guide_rgb = a.midi.useFastLed();
            a.player.pushFullLedSync();
            a.flushLedToMidi();
            a.saveConfig();
            a.setStatus("FastLED {s}", .{if (a.midi.fast_led_enabled) "ON" else "OFF"});
        }
        const fastled_hint = if (a.midi.model.supportsFastLed())
            (if (a.midi.fast_led_enabled) "0x5F RGB SysEx active" else "Standard Note-On (device palette)")
        else
            "CoreFW / Pro CFW only";
        g.text(fastled_hint, field_x + 140, r3y + 8, 12, gfx.dim);

        y += midi_card_h + 12;

        // === Card 2: Audio Engine ===
        const audio_card_h: f32 = 170;
        g.roundBox(lx, y, cw, audio_card_h, 12, gfx.card, gfx.border_col.alpha(130));
        g.text("AUDIO ENGINE", lx + 16, y + 12, 12, gfx.accent);
        g.textRight(if (builtin.os.tag == .linux) "Direct ALSA" else "PortAudio", lx + cw - 16, y + 12, 12, gfx.dim);

        // Row 1: Output Device Dropdown
        const a1y = y + 40;
        g.text("Output", lx + 16, a1y + 8, 14, gfx.dim);
        const cur_dev_label = if (a.audio_device_idx < a.audio_labels.len) a.audio_labels[a.audio_device_idx] else "System Default";
        const full_field_w = cw - 120;
        if (a.dropdown.trigger(g, .audio_device, field_x, a1y, full_field_w, 34, cur_dev_label, !drop_open)) {
            a.dropdown.show(.audio_device, a.audio_labels, a.audio_device_idx);
        }

        // Row 2: Buffer Size segmented control
        const a2y = y + 84;
        g.text("Buffer", lx + 16, a2y + 8, 14, gfx.dim);
        const sizes = [_]u32{ 64, 128, 256, 512 };
        g.roundBox(field_x, a2y, full_field_w, 34, 8, gfx.surface, gfx.border_col);
        const seg_w = (full_field_w - 8) / sizes.len;
        for (sizes, 0..) |sz, i| {
            const sx = field_x + 4 + seg_w * @as(f32, @floatFromInt(i));
            const active = a.audio_frames == sz;
            const hover = !drop_open and g.hit(sx, a2y + 4, seg_w, 26);
            if (active) {
                g.round(sx, a2y + 4, seg_w, 26, 6, gfx.accent);
            } else if (hover) {
                g.round(sx, a2y + 4, seg_w, 26, 6, gfx.panel_col);
            }
            g.fmtCentered(sx + seg_w / 2, a2y + 17, 12, if (active) gfx.white else gfx.dim, "{d} f", .{sz});
            if (!drop_open and g.clickIn(sx, a2y + 4, seg_w, 26)) {
                a.audio_frames = sz;
                a.applyAudioSettings();
            }
        }

        // Row 3: Master Volume slider + Anti-Pop toggle
        const a3y = y + 128;
        g.text("Volume", lx + 16, a3y + 6, 14, gfx.dim);
        if (a.slider(.volume, field_x, a3y + 2, full_field_w - 170, 26, a.volume, 0.0, 1.5, !drop_open)) |nv| {
            a.volume = nv;
            a.engine.setGain(nv);
        }
        g.fmt(field_x + full_field_w - 158, a3y + 7, 14, gfx.white, "{d}%", .{@as(u32, @intFromFloat(@round(a.volume * 100)))});
        if (a.pillToggle(field_x + full_field_w - 102, a3y - 1, 102, 32, "Anti-Pop", a.anti_pop)) {
            a.anti_pop = !a.anti_pop;
            a.engine.setAntiPop(a.anti_pop);
            a.saveConfig();
        }

        y += audio_card_h + 12;

        // === Card 3: Playback ===
        const play_card_h: f32 = 132;
        g.roundBox(lx, y, cw, play_card_h, 12, gfx.card, gfx.border_col.alpha(130));
        g.text("PLAYBACK", lx + 16, y + 12, 12, gfx.accent);

        // Row 1: 3 toggle pills
        const p1y = y + 38;
        const tw = (cw - 32 - 16) / 3;
        if (a.pillToggle(lx + 16, p1y, tw, 34, "LED Output", a.player.led_enabled)) {
            a.player.led_enabled = !a.player.led_enabled;
            if (!a.player.led_enabled) a.player.clearLeds();
            a.saveConfig();
        }
        if (a.pillToggle(lx + 16 + tw + 8, p1y, tw, 34, "Chain LED", a.player.show_chain)) {
            a.player.setShowChain(!a.player.show_chain);
            a.saveConfig();
        }
        if (a.pillToggle(lx + 16 + (tw + 8) * 2, p1y, tw, 34, "Guide Mode", a.player.guide_mode)) {
            a.player.setGuideMode(!a.player.guide_mode);
            a.flushLedToMidi();
            a.saveConfig();
        }

        // Row 2: Speed slider + 1.0x reset
        const p2y = y + 84;
        g.text("Speed", lx + 16, p2y + 6, 14, gfx.dim);
        if (a.slider(.speed, field_x, p2y + 2, full_field_w - 114, 26, a.player.speed_multiplier, 0.25, 2.0, !drop_open)) |ns| {
            a.player.speed_multiplier = @round(ns * 20.0) / 20.0;
        }
        g.fmt(field_x + full_field_w - 104, p2y + 7, 14, gfx.white, "{d:.2}x", .{a.player.speed_multiplier});
        if (a.button(field_x + full_field_w - 50, p2y + 1, 50, 28, "1.0x", false)) {
            a.player.speed_multiplier = 1.0;
            a.saveConfig();
        }

        // Draw active dropdown popup ON TOP of everything
        if (drop_open) {
            const target = a.dropdown.target;
            if (a.dropdown.drawPopup(g, saved_click)) |picked| {
                a.applyDropdownChoice(target, picked);
            }
        } else if (g.clicked and !g.hit(px, py, pw, ph)) {
            g.clicked = false;
            a.settings_open = false;
        }
    }

    fn currentMidiPortIndex(a: *const App) usize {
        for (a.midi_ports, 0..) |pt, i| {
            if ((a.midi.connected_in != null and a.midi.connected_in.? == pt.id) or
                (a.midi.connected_out != null and a.midi.connected_out.? == pt.id))
            {
                return i + 1;
            }
        }
        return 0;
    }

    fn applyDropdownChoice(a: *App, target: dropdown_mod.Target, idx: usize) void {
        switch (target) {
            .none => {},
            .midi_model => {
                const models = std.enums.values(midi_driver.Model);
                if (idx == 0) {
                    a.midi.auto_model = true;
                    a.refreshDevices();
                    if (a.midi.autoConnect(a.ports_arena.allocator())) {
                        a.player.smooth_guide_rgb = a.midi.useFastLed();
                        a.player.pushFullLedSync();
                        a.flushLedToMidi();
                        a.setStatus("Auto-detected: {s}", .{a.midi.model.displayName()});
                    } else {
                        a.setStatus("Model set to Auto-Detect", .{});
                    }
                } else if (idx - 1 < models.len) {
                    a.midi.auto_model = false;
                    a.midi.model = models[idx - 1];
                    a.midi.sendInit();
                    a.player.smooth_guide_rgb = a.midi.useFastLed();
                    a.player.pushFullLedSync();
                    a.flushLedToMidi();
                    a.setStatus("Model: {s}", .{a.midi.model.displayName()});
                }
            },
            .midi_port => {
                if (idx == 0) {
                    a.midi.sendClearLed();
                    a.midi.disconnect();
                    a.setStatus("MIDI disconnected", .{});
                } else if (idx - 1 < a.midi_ports.len) {
                    const pt = a.midi_ports[idx - 1];
                    if (a.midi.auto_model) {
                        if (pt.detected) |det| a.midi.model = det;
                    }
                    a.midi.connect(
                        if (pt.can_read) pt.id else a.midi.connected_in,
                        if (pt.can_write) pt.id else a.midi.connected_out,
                        pt.name,
                    );
                    a.player.pushFullLedSync();
                    a.flushLedToMidi();
                    a.setStatus("MIDI port: {s}", .{pt.name});
                }
            },
            .audio_device => {
                if (idx < a.audio_labels.len) {
                    a.audio_device_idx = idx;
                    a.applyAudioSettings();
                }
            },
        }
        a.saveConfig();
    }

    fn applyAudioSettings(a: *App) void {
        const dev = if (a.audio_device_idx == 0 or a.audio_device_idx > a.audio_devices.len)
            ""
        else
            a.audio_devices[a.audio_device_idx - 1];
        a.engine.reopen(a.audio_frames, dev);
        a.saveConfig();
        a.setStatus("Audio: {s} ({d} frames)", .{ if (dev.len > 0) dev else "default", a.engine.feed_frames });
    }

    fn button(a: *App, x: f32, y: f32, w: f32, h: f32, label: []const u8, active: bool) bool {
        const g = &a.g;
        const hovered = g.hit(x, y, w, h);
        const fill = if (active) gfx.accent else if (hovered) gfx.panel_col else gfx.card;
        const stroke = if (active) gfx.accent else if (hovered) gfx.dim else gfx.border_col;
        g.roundBox(x, y, w, h, 8, fill, stroke);
        g.textCentered(label, x + w / 2, y + h / 2, 14, gfx.white);
        return g.clickIn(x, y, w, h);
    }

    fn pillToggle(a: *App, x: f32, y: f32, w: f32, h: f32, label: []const u8, on: bool) bool {
        const g = &a.g;
        const hovered = g.hit(x, y, w, h);
        const fill = if (on) gfx.accent.alpha(34) else if (hovered) gfx.panel_col else gfx.surface;
        const stroke = if (on) gfx.accent else if (hovered) gfx.dim else gfx.border_col;
        g.roundBox(x, y, w, h, 8, fill, stroke);
        g.disc(x + 15, y + h / 2, 4.0, if (on) gfx.good else gfx.dim.alpha(120));
        g.text(label, x + 26, y + (h - 16) / 2, 14, if (on) gfx.white else gfx.dim);
        return g.clickIn(x, y, w, h);
    }

    fn slider(a: *App, id: DragSlider, x: f32, y: f32, w: f32, h: f32, val: f32, min_v: f32, max_v: f32, allow: bool) ?f32 {
        const g = &a.g;
        const cy = y + h / 2;
        const t = std.math.clamp((val - min_v) / (max_v - min_v), 0.0, 1.0);
        const fill_w = @max(w * t, 6.0);

        g.round(x, cy - 3, w, 6, 3, gfx.surface);
        g.round(x, cy - 3, fill_w, 6, 3, gfx.accent);
        const knob_x = x + w * t;
        const hovered = allow and g.hit(x - 6, y, w + 12, h);
        g.disc(knob_x, cy, if (hovered or a.dragging_slider == id) 8.5 else 7.0, gfx.white);
        g.disc(knob_x, cy, 3.5, gfx.accent);

        if (allow and g.clickIn(x - 6, y, w + 12, h)) {
            a.dragging_slider = id;
        }
        if (allow and g.down and a.dragging_slider == id) {
            const nt = std.math.clamp((g.mx - x) / w, 0.0, 1.0);
            return min_v + (max_v - min_v) * nt;
        }
        return null;
    }
};

fn ledColor(argb: u32) Color {
    const c_in = Color.fromArgb(argb);
    const a_f = @as(f32, @floatFromInt(c_in.a)) / 255.0;
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(c_in.r)) * a_f),
        .g = @intFromFloat(@as(f32, @floatFromInt(c_in.g)) * a_f),
        .b = @intFromFloat(@as(f32, @floatFromInt(c_in.b)) * a_f),
        .a = 255,
    };
}

fn samePad(a: ?PadCoord, b: ?PadCoord) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.row == b.?.row and a.?.col == b.?.col;
}

pub fn nowMs() f64 {
    return @as(f64, @floatFromInt(c.SDL_GetTicksNS())) / 1_000_000.0;
}
