//! MIDI protocol drivers for all Novation Launchpad models and custom firmwares.
//! Ported from official unipad-android drivers (S/Mini, MK2, Pro, Pro CFW, CoreFW, X, Mini MK3, Pro MK3).
const std = @import("std");
const palette = @import("../unipack/palette.zig");

pub const Model = enum {
    launchpad_s,
    launchpad_mk2,
    launchpad_pro,
    launchpad_pro_cfw,
    launchpad_corefw_rgb,
    launchpad_corefw_s,
    launchpad_x,
    launchpad_mini_mk3,
    launchpad_pro_mk3,

    pub fn displayName(m: Model) []const u8 {
        return switch (m) {
            .launchpad_s => "Launchpad S / Mini",
            .launchpad_mk2 => "Launchpad MK2",
            .launchpad_pro => "Launchpad Pro",
            .launchpad_pro_cfw => "Launchpad Pro (CFW)",
            .launchpad_corefw_rgb => "Launchpad CoreFW (RGB)",
            .launchpad_corefw_s => "Launchpad CoreFW (S/Mini)",
            .launchpad_x => "Launchpad X",
            .launchpad_mini_mk3 => "Launchpad Mini MK3",
            .launchpad_pro_mk3 => "Launchpad Pro MK3",
        };
    }

    /// Preferred 0-based USB-MIDI port/cable index on multi-port models.
    pub fn preferredPortIndex(m: Model) u8 {
        return switch (m) {
            .launchpad_x, .launchpad_mini_mk3, .launchpad_corefw_rgb, .launchpad_corefw_s => 1,
            else => 0,
        };
    }

    /// True when the firmware supports the Apollo FastLED RGB SysEx (`0xF0 0x5F ... 0xF7`).
    pub fn supportsFastLed(m: Model) bool {
        return m == .launchpad_corefw_rgb or m == .launchpad_pro_cfw;
    }

    pub fn initSysEx(m: Model) []const []const u8 {
        return switch (m) {
            .launchpad_pro => &.{
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x21, 0x00, 0xF7 }, // Live mode
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x22, 0x00, 0xF7 }, // Session layout
            },
            .launchpad_pro_cfw => &.{
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x21, 0x01, 0xF7 }, // Performance mode
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0E, 0x00, 0xF7 }, // Clear canvas
            },
            .launchpad_x => &.{
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x10, 0x00, 0xF7 }, // Standalone
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x0E, 0x01, 0xF7 }, // Programmer mode
            },
            .launchpad_mini_mk3 => &.{
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x10, 0x00, 0xF7 }, // Standalone
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x0E, 0x01, 0xF7 }, // Programmer mode
            },
            .launchpad_pro_mk3 => &.{
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0E, 0x10, 0x00, 0xF7 }, // Standalone
                &.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0E, 0x0E, 0x01, 0xF7 }, // Programmer mode
            },
            else => &.{},
        };
    }
};

pub const InputEvent = union(enum) {
    pad: struct { row: u8, col: u8, pressed: bool, velocity: u8 },
    chain: struct { chain: u8, pressed: bool },
    function_key: struct { idx: u8, pressed: bool },
};

pub const OutMsg = struct {
    buf: [16]u8 = undefined,
    len: u8 = 0,

    pub fn slice(m: *const OutMsg) []const u8 {
        return m.buf[0..m.len];
    }

    pub fn short3(status: u8, d1: u8, d2: u8) OutMsg {
        var m: OutMsg = .{ .len = 3 };
        m.buf[0] = status;
        m.buf[1] = @min(d1, 127);
        m.buf[2] = @min(d2, 127);
        return m;
    }

    pub fn fromBytes(bytes: []const u8) OutMsg {
        var m: OutMsg = .{ .len = @intCast(@min(bytes.len, 16)) };
        @memcpy(m.buf[0..m.len], bytes[0..m.len]);
        return m;
    }
};

const s_ring_code = [16][2]u8{
    .{ 0xB0, 104 }, .{ 0xB0, 105 }, .{ 0xB0, 106 }, .{ 0xB0, 107 },
    .{ 0xB0, 108 }, .{ 0xB0, 109 }, .{ 0xB0, 110 }, .{ 0xB0, 111 },
    .{ 0x90, 8 },   .{ 0x90, 24 },  .{ 0x90, 40 },  .{ 0x90, 56 },
    .{ 0x90, 72 },  .{ 0x90, 88 },  .{ 0x90, 104 }, .{ 0x90, 120 },
};

const mk2_ring_code = [16][2]u8{
    .{ 0xB0, 104 }, .{ 0xB0, 105 }, .{ 0xB0, 106 }, .{ 0xB0, 107 },
    .{ 0xB0, 108 }, .{ 0xB0, 109 }, .{ 0xB0, 110 }, .{ 0xB0, 111 },
    .{ 0x90, 89 },  .{ 0x90, 79 },  .{ 0x90, 69 },  .{ 0x90, 59 },
    .{ 0x90, 49 },  .{ 0x90, 39 },  .{ 0x90, 29 },  .{ 0x90, 19 },
};

const pro_ring_cc = [32]u8{
    91, 92, 93, 94, 95, 96, 97, 98, // Top (0..7)
    89, 79, 69, 59, 49, 39, 29, 19, // Right (8..15 -> chains 0..7)
    8,  7,  6,  5,  4,  3,  2,  1, // Bottom (16..23 -> chains 8..15)
    10, 20, 30, 40, 50, 60, 70, 80, // Left (24..31 -> chains 16..23)
};

/// Auto-detects Launchpad model from USB VID/PID/serial (when available) and MIDI port/device name.
pub fn detectModel(name: []const u8, vid: u16, pid: u16, serial: []const u8) ?Model {
    if (containsIgnoreCase(name, "Launchpad Open")) return .launchpad_pro_cfw;

    const is_corefw = std.mem.startsWith(u8, serial, "COREFW-");
    if (vid == 0x1235) {
        if (pid == 0x000E) return .launchpad_s;
        if ((pid >= 0x0020 and pid <= 0x002F) or pid == 0x0036)
            return if (is_corefw) .launchpad_corefw_s else .launchpad_s;
        if (pid >= 0x0051 and pid <= 0x0060)
            return if (is_corefw) .launchpad_corefw_rgb else .launchpad_pro;
        if (pid >= 0x0069 and pid <= 0x0078)
            return if (is_corefw) .launchpad_corefw_rgb else .launchpad_mk2;
        if (pid >= 0x0103 and pid <= 0x0112)
            return if (is_corefw) .launchpad_corefw_rgb else .launchpad_x;
        if (pid >= 0x0113 and pid <= 0x0122)
            return if (is_corefw) .launchpad_corefw_rgb else .launchpad_mini_mk3;
        if (pid >= 0x0123 and pid <= 0x0132)
            return if (is_corefw) .launchpad_corefw_rgb else .launchpad_pro_mk3;
    }

    if (containsIgnoreCase(name, "CoreFW")) return .launchpad_corefw_rgb;
    if (containsIgnoreCase(name, "Pro MK3") or containsIgnoreCase(name, "LPProMK3")) return .launchpad_pro_mk3;
    if (containsIgnoreCase(name, "Mini MK3") or containsIgnoreCase(name, "LPMiniMK3")) return .launchpad_mini_mk3;
    if (containsIgnoreCase(name, "Launchpad X") or containsIgnoreCase(name, "LPX")) return .launchpad_x;
    if (containsIgnoreCase(name, "Launchpad Pro")) return .launchpad_pro;
    if (containsIgnoreCase(name, "Launchpad MK2")) return .launchpad_mk2;
    if (containsIgnoreCase(name, "Launchpad S") or containsIgnoreCase(name, "Launchpad Mini") or containsIgnoreCase(name, "Launchpad")) return .launchpad_s;
    return null;
}

/// Decodes an incoming 3-byte MIDI message (status, data1, data2) into a UniPad input event.
pub fn decodeInput(model: Model, status: u8, data1: u8, data2: u8) ?InputEvent {
    const kind = status & 0xF0;
    const is_note_on = kind == 0x90;
    const is_note_off = kind == 0x80;
    const is_cc = kind == 0xB0;
    const pressed = !is_note_off and data2 > 0;

    switch (model) {
        .launchpad_s => {
            if (is_note_on or is_note_off) {
                const row = data1 / 16;
                const col = data1 % 16;
                if (row < 8 and col < 8) return .{ .pad = .{ .row = row, .col = col, .pressed = pressed, .velocity = data2 } };
                if (row < 8 and col == 8) return .{ .chain = .{ .chain = row, .pressed = pressed } };
            } else if (is_cc and data1 >= 104 and data1 <= 111) {
                return .{ .function_key = .{ .idx = data1 - 104, .pressed = pressed } };
            }
            return null;
        },
        .launchpad_mk2 => {
            if (is_note_on or is_note_off) {
                const r_ten = data1 / 10;
                const c_one = data1 % 10;
                if (r_ten >= 1 and r_ten <= 8) {
                    const row: u8 = 8 - r_ten;
                    if (c_one >= 1 and c_one <= 8) return .{ .pad = .{ .row = row, .col = c_one - 1, .pressed = pressed, .velocity = data2 } };
                    if (c_one == 9) return .{ .chain = .{ .chain = row, .pressed = pressed } };
                }
            } else if (is_cc and data1 >= 104 and data1 <= 111) {
                return .{ .function_key = .{ .idx = data1 - 104, .pressed = pressed } };
            }
            return null;
        },
        .launchpad_pro, .launchpad_x, .launchpad_mini_mk3, .launchpad_pro_mk3 => {
            if (is_note_on or is_note_off) {
                const r_ten = data1 / 10;
                const c_one = data1 % 10;
                if (r_ten >= 1 and r_ten <= 8 and c_one >= 1 and c_one <= 8) {
                    return .{ .pad = .{ .row = 8 - r_ten, .col = c_one - 1, .pressed = pressed, .velocity = data2 } };
                }
            } else if (is_cc) {
                if (data1 >= 91 and data1 <= 98) return .{ .function_key = .{ .idx = data1 - 91, .pressed = pressed } };
                if (data1 >= 19 and data1 <= 89 and data1 % 10 == 9) return .{ .chain = .{ .chain = 8 - data1 / 10, .pressed = pressed } };
                if (data1 >= 1 and data1 <= 8) return .{ .chain = .{ .chain = 16 - data1, .pressed = pressed } };
                if (data1 >= 10 and data1 <= 80 and data1 % 10 == 0) return .{ .chain = .{ .chain = 15 + data1 / 10, .pressed = pressed } };
            }
            return null;
        },
        .launchpad_pro_cfw, .launchpad_corefw_rgb, .launchpad_corefw_s => {
            if (!is_note_on and !is_note_off and !is_cc) return null;
            if (data1 >= 36 and data1 <= 99) {
                const idx = data1 - 36;
                const row: u8 = 7 - (idx % 32) / 4;
                const col: u8 = if (idx < 32) idx % 4 else (idx % 4) + 4;
                return .{ .pad = .{ .row = row, .col = col, .pressed = pressed, .velocity = data2 } };
            }
            if (data1 >= 28 and data1 <= 35) return .{ .function_key = .{ .idx = data1 - 28, .pressed = pressed } };
            if (data1 >= 100 and data1 <= 107) return .{ .chain = .{ .chain = data1 - 100, .pressed = pressed } };
            if (data1 >= 116 and data1 <= 123) return .{ .chain = .{ .chain = 15 - (data1 - 116), .pressed = pressed } };
            if (data1 >= 108 and data1 <= 115) return .{ .chain = .{ .chain = 23 - (data1 - 108), .pressed = pressed } };
            if (data1 == 27) return .{ .function_key = .{ .idx = 32, .pressed = pressed } };
            return null;
        },
    }
}

/// Encodes a pad LED update (row 0..7, col 0..7, velocity 0..127) into a MIDI message.
pub fn encodePadLed(model: Model, row: u8, col: u8, velocity: u8) ?OutMsg {
    if (row >= 8 or col >= 8) return null;
    const vel = @min(velocity, 127);
    return switch (model) {
        .launchpad_s => OutMsg.short3(0x90, row * 16 + col, palette.scodeOf(vel)),
        .launchpad_mk2, .launchpad_pro, .launchpad_x, .launchpad_mini_mk3, .launchpad_pro_mk3 => OutMsg.short3(0x90, 10 * (8 - row) + col + 1, vel),
        .launchpad_pro_cfw => OutMsg.short3(0x9F, drumRackPadNote(row, col), vel),
        .launchpad_corefw_rgb => OutMsg.short3(0x90, drumRackPadNote(row, col), vel),
        .launchpad_corefw_s => OutMsg.short3(0x90, drumRackPadNote(row, col), palette.scodeOf(vel)),
    };
}

/// Encodes a ring (0..31) or logo (32) LED update into a MIDI message.
pub fn encodeRingLed(model: Model, idx: u8, velocity: u8) ?OutMsg {
    const vel = @min(velocity, 127);
    switch (model) {
        .launchpad_s => {
            if (idx >= 16) return null;
            return OutMsg.short3(s_ring_code[idx][0], s_ring_code[idx][1], palette.scodeOf(vel));
        },
        .launchpad_mk2 => {
            if (idx >= 16) return null;
            return OutMsg.short3(mk2_ring_code[idx][0], mk2_ring_code[idx][1], vel);
        },
        .launchpad_pro => {
            if (idx < 32) return OutMsg.short3(0xB0, pro_ring_cc[idx], vel);
            if (idx == 32) return OutMsg.fromBytes(&.{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0A, 0x63, vel, 0xF7 });
            return null;
        },
        .launchpad_x, .launchpad_mini_mk3, .launchpad_pro_mk3 => {
            if (idx < 32) return OutMsg.short3(0xB0, pro_ring_cc[idx], vel);
            if (idx == 32) return OutMsg.short3(0xB0, 99, vel);
            return null;
        },
        .launchpad_pro_cfw, .launchpad_corefw_rgb, .launchpad_corefw_s => {
            const note = drumRackRingNote(idx) orelse return null;
            const status: u8 = if (model == .launchpad_pro_cfw) 0x9F else 0x90;
            const out_v: u8 = if (model == .launchpad_corefw_s) palette.scodeOf(vel) else vel;
            return OutMsg.short3(status, note, out_v);
        },
    }
}

fn drumRackPadNote(row: u8, col: u8) u8 {
    const inv = 7 - row;
    return if (col < 4) 36 + inv * 4 + col else 68 + inv * 4 + (col - 4);
}

fn drumRackRingNote(idx: u8) ?u8 {
    if (idx <= 7) return 28 + idx;
    if (idx <= 15) return 100 + (idx - 8);
    if (idx <= 23) return 123 - (idx - 16);
    if (idx <= 31) return 115 - (idx - 24);
    if (idx == 32) return 27;
    return null;
}

pub const Rgb6 = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn eql(a: Rgb6, b: Rgb6) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// Resolves LED color to 6-bit Launchpad hardware RGB (0..63).
/// Palette events (`auto <vel>`) use the Novation hardware RGB palette, not UniPad's screen palette.
/// Explicit custom HEX colors (`argb != palette.argbOf(vel)`) send their direct 6-bit RGB.
pub fn argbToRgb6(argb: u32, velocity: u8) Rgb6 {
    if (argb == 0 or argb == palette.argbOf(velocity)) {
        const rgb = palette.novationRgb6(velocity);
        return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
    }
    const a: u32 = (argb >> 24) & 0xFF;
    if (a == 0) return .{};
    const r8: u32 = (((argb >> 16) & 0xFF) * a) / 255;
    const g8: u32 = (((argb >> 8) & 0xFF) * a) / 255;
    const b8: u32 = ((argb & 0xFF) * a) / 255;
    return .{
        .r = @intCast(r8 >> 2),
        .g = @intCast(g8 >> 2),
        .b = @intCast(b8 >> 2),
    };
}

pub fn fastLedPadTarget(row: u8, col: u8) ?u8 {
    if (row >= 8 or col >= 8) return null;
    return 10 * (8 - row) + col + 1;
}

pub fn fastLedRingTarget(idx: u8) ?u8 {
    if (idx < 32) return pro_ring_cc[idx];
    if (idx == 32) return 99;
    return null;
}

/// Zero-alloc frame batcher for CoreFW / LPP CFW FastLED SysEx (`0xF0 0x5F ... 0xF7`).
/// Deduplicates per-target writes within a frame, groups identical colors, and splits at 240B.
pub const FastLedBatch = struct {
    pub const max_packet_bytes: usize = 240;

    dirty: [100]bool = @splat(false),
    colors: [100]Rgb6 = @splat(.{}),
    clear_all: bool = false,

    pub fn reset(b: *FastLedBatch) void {
        b.dirty = @splat(false);
        b.clear_all = false;
    }

    pub fn clear(b: *FastLedBatch) void {
        b.dirty = @splat(false);
        b.clear_all = true;
    }

    pub fn setPad(b: *FastLedBatch, row: u8, col: u8, rgb: Rgb6) void {
        const target = fastLedPadTarget(row, col) orelse return;
        b.dirty[target] = true;
        b.colors[target] = rgb;
    }

    pub fn setRing(b: *FastLedBatch, idx: u8, rgb: Rgb6) void {
        const target = fastLedRingTarget(idx) orelse return;
        b.dirty[target] = true;
        b.colors[target] = rgb;
    }

    pub fn flush(b: *FastLedBatch, ctx: anytype, comptime sendFn: fn (@TypeOf(ctx), []const u8) void) void {
        var pkt: [max_packet_bytes]u8 = undefined;
        pkt[0] = 0xF0;
        pkt[1] = 0x5F;
        var pos: usize = 2;

        if (b.clear_all) {
            // 0 clears 0..98; 1..8 also clears Pro Mk3 mirrored lower row; 99 clears logo.
            const clear_group = [_]u8{ 0, 0, 0, 10, 0, 1, 2, 3, 4, 5, 6, 7, 8, 99 };
            @memcpy(pkt[pos .. pos + clear_group.len], &clear_group);
            pos += clear_group.len;
        }

        var emitted: [100]bool = @splat(false);
        var targets: [99]u8 = undefined;

        for (1..100) |t| {
            if (!b.dirty[t] or emitted[t]) continue;
            const rgb = b.colors[t];
            if (b.clear_all and rgb.r == 0 and rgb.g == 0 and rgb.b == 0) {
                emitted[t] = true;
                continue;
            }

            var count: usize = 0;
            for (t..100) |u| {
                if (b.dirty[u] and !emitted[u] and b.colors[u].eql(rgb)) {
                    targets[count] = @intCast(u);
                    count += 1;
                    emitted[u] = true;
                }
            }

            var off: usize = 0;
            while (off < count) {
                const rem = count - off;
                const hdr_min: usize = if (rem <= 7) 3 else 4;
                if (pos + hdr_min + 2 > max_packet_bytes) {
                    pkt[pos] = 0xF7;
                    sendFn(ctx, pkt[0 .. pos + 1]);
                    pkt[0] = 0xF0;
                    pkt[1] = 0x5F;
                    pos = 2;
                }

                const avail = max_packet_bytes - 1 - pos;
                const take: usize = if (rem <= 7)
                    @min(rem, avail - 3)
                else if (avail >= 12)
                    @min(rem, avail - 4)
                else
                    @min(@as(usize, 7), avail - 3);

                if (take <= 7) {
                    const n: u8 = @intCast(take);
                    pkt[pos] = (rgb.r & 0x3F) | (((n >> 2) & 1) << 6);
                    pkt[pos + 1] = (rgb.g & 0x3F) | (((n >> 1) & 1) << 6);
                    pkt[pos + 2] = (rgb.b & 0x3F) | ((n & 1) << 6);
                    pos += 3;
                } else {
                    pkt[pos] = rgb.r & 0x3F;
                    pkt[pos + 1] = rgb.g & 0x3F;
                    pkt[pos + 2] = rgb.b & 0x3F;
                    pkt[pos + 3] = @intCast(take);
                    pos += 4;
                }
                @memcpy(pkt[pos .. pos + take], targets[off .. off + take]);
                pos += take;
                off += take;
            }
        }

        if (pos > 2) {
            pkt[pos] = 0xF7;
            sendFn(ctx, pkt[0 .. pos + 1]);
        }
        b.reset();
    }
};

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "all Launchpad models round-trip pad and chain coordinates" {
    const models = std.enums.values(Model);
    for (models) |m| {
        // Test corner and center pads
        for ([_][2]u8{ .{ 0, 0 }, .{ 0, 7 }, .{ 7, 0 }, .{ 7, 7 }, .{ 3, 4 } }) |rc| {
            const msg = encodePadLed(m, rc[0], rc[1], 5).?;
            const ev = decodeInput(m, msg.buf[0], msg.buf[1], 127).?;
            try std.testing.expectEqual(rc[0], ev.pad.row);
            try std.testing.expectEqual(rc[1], ev.pad.col);
            try std.testing.expect(ev.pad.pressed);
        }
        // Test chain 0 (ring 8)
        const cmsg = encodeRingLed(m, 8, 3).?;
        const cev = decodeInput(m, cmsg.buf[0], cmsg.buf[1], 127).?;
        try std.testing.expectEqual(@as(u8, 0), cev.chain.chain);
    }

    try std.testing.expectEqual(@as(?Model, .launchpad_pro_mk3), detectModel("Launchpad Pro MK3", 0x1235, 0x0123, ""));
    try std.testing.expectEqual(@as(?Model, .launchpad_corefw_rgb), detectModel("Launchpad X", 0x1235, 0x0103, "COREFW-1234"));
    try std.testing.expectEqual(@as(?Model, .launchpad_pro_cfw), detectModel("Launchpad Open", 0x1235, 0x0051, ""));
}

test "FastLED 0x5F batching, clear, grouping, alpha, and packet splitting" {
    try std.testing.expect(Model.launchpad_corefw_rgb.supportsFastLed());
    try std.testing.expect(Model.launchpad_pro_cfw.supportsFastLed());
    try std.testing.expect(!Model.launchpad_corefw_s.supportsFastLed());
    try std.testing.expect(!Model.launchpad_pro_mk3.supportsFastLed());

    // Palette velocities map to Novation hardware 6-bit RGB, not UniPad's UI pastel palette
    try std.testing.expectEqual(Rgb6{ .r = 15, .g = 15, .b = 15 }, argbToRgb6(palette.argbOf(1), 1));
    try std.testing.expectEqual(Rgb6{ .r = 31, .g = 31, .b = 31 }, argbToRgb6(palette.argbOf(2), 2));
    try std.testing.expectEqual(Rgb6{ .r = 63, .g = 63, .b = 63 }, argbToRgb6(palette.argbOf(3), 3));
    try std.testing.expectEqual(Rgb6{ .r = 63, .g = 0, .b = 0 }, argbToRgb6(palette.argbOf(5), 5));
    try std.testing.expectEqual(Rgb6{ .r = 0, .g = 63, .b = 0 }, argbToRgb6(palette.argbOf(21), 21));
    try std.testing.expectEqual(Rgb6{ .r = 0, .g = 0, .b = 63 }, argbToRgb6(palette.argbOf(45), 45));
    try std.testing.expectEqual(Rgb6{ .r = 63, .g = 32, .b = 0 }, argbToRgb6(0xFFFF8000, 0));

    // Reference CoreFW / LPP CFW 0x5F decoder
    const Sink = struct {
        leds: [109]Rgb6 = @splat(.{}),
        packets: usize = 0,
        max_len: usize = 0,
        bad_bytes: usize = 0,

        fn receive(self: *@This(), pkt: []const u8) void {
            self.packets += 1;
            self.max_len = @max(self.max_len, pkt.len);
            if (pkt.len < 3 or pkt[0] != 0xF0 or pkt[1] != 0x5F or pkt[pkt.len - 1] != 0xF7) {
                self.bad_bytes += 1;
                return;
            }
            for (pkt[1 .. pkt.len - 1]) |byte| {
                if (byte >= 0x80) self.bad_bytes += 1;
            }
            var i: usize = 2;
            const end = pkt.len - 1;
            while (i < end) {
                if (i + 3 > end) break;
                const r0 = pkt[i];
                const g0 = pkt[i + 1];
                const b0 = pkt[i + 2];
                i += 3;
                var n: usize = ((r0 & 0x40) >> 4) | ((g0 & 0x40) >> 5) | ((b0 & 0x40) >> 6);
                if (n == 0) {
                    if (i >= end) break;
                    n = pkt[i];
                    i += 1;
                }
                const rgb: Rgb6 = .{ .r = r0 & 0x3F, .g = g0 & 0x3F, .b = b0 & 0x3F };
                var k: usize = 0;
                while (k < n and i < end) : ({
                    k += 1;
                    i += 1;
                }) {
                    const target = pkt[i];
                    if (target == 0) {
                        for (0..99) |idx| self.leds[idx] = rgb;
                    } else if (target <= 8) {
                        self.leds[target] = rgb;
                        self.leds[100 + target] = rgb;
                    } else if (target <= 99) {
                        self.leds[target] = rgb;
                    }
                }
            }
        }
    };

    var sink: Sink = .{};
    sink.leds[55] = .{ .r = 10, .g = 20, .b = 30 };
    sink.leds[99] = .{ .r = 10, .g = 20, .b = 30 };
    sink.leds[105] = .{ .r = 10, .g = 20, .b = 30 };

    // 1. Clear + grouped compact (<=7) + explicit (>=8) + dedup in a single packet
    var batch: FastLedBatch = .{};
    batch.clear();
    batch.setPad(0, 0, .{ .r = 1, .g = 2, .b = 3 });
    batch.setPad(0, 0, .{ .r = 60, .g = 10, .b = 5 }); // overrides previous write
    batch.setRing(8, .{ .r = 60, .g = 10, .b = 5 }); // chain 0 -> target 89, grouped with pad (0,0)
    batch.setRing(32, .{ .r = 0, .g = 63, .b = 31 }); // logo -> target 99
    // 10 pads with identical blue -> triggers explicit count byte (>=8)
    for (0..8) |col_i| batch.setPad(7, @intCast(col_i), .{ .r = 0, .g = 0, .b = 50 });
    batch.setPad(6, 0, .{ .r = 0, .g = 0, .b = 50 });
    batch.setPad(6, 1, .{ .r = 0, .g = 0, .b = 50 });
    batch.flush(&sink, Sink.receive);

    try std.testing.expectEqual(@as(usize, 0), sink.bad_bytes);
    try std.testing.expectEqual(@as(usize, 1), sink.packets);
    try std.testing.expect(sink.max_len <= FastLedBatch.max_packet_bytes);
    try std.testing.expectEqual(Rgb6{}, sink.leds[55]);
    try std.testing.expectEqual(Rgb6{}, sink.leds[105]);
    try std.testing.expectEqual(Rgb6{ .r = 60, .g = 10, .b = 5 }, sink.leds[81]);
    try std.testing.expectEqual(Rgb6{ .r = 60, .g = 10, .b = 5 }, sink.leds[89]);
    try std.testing.expectEqual(Rgb6{ .r = 0, .g = 63, .b = 31 }, sink.leds[99]);
    for (11..19) |t| try std.testing.expectEqual(Rgb6{ .r = 0, .g = 0, .b = 50 }, sink.leds[t]);
    try std.testing.expectEqual(Rgb6{ .r = 0, .g = 0, .b = 50 }, sink.leds[21]);
    try std.testing.expectEqual(Rgb6{ .r = 0, .g = 0, .b = 50 }, sink.leds[22]);

    // 2. Worst-case 97 unique colors splits cleanly across multiple <=240B packets
    sink = .{};
    for (0..8) |r| {
        for (0..8) |c_i| {
            const k: u8 = @intCast(r * 8 + c_i + 1);
            batch.setPad(@intCast(r), @intCast(c_i), .{ .r = k & 63, .g = (k *% 3) & 63, .b = (k *% 7) & 63 });
        }
    }
    for (0..33) |i| {
        const k: u8 = @intCast(i + 1);
        batch.setRing(@intCast(i), .{ .r = 63 - k, .g = k, .b = (k *% 2) & 63 });
    }
    batch.flush(&sink, Sink.receive);

    try std.testing.expectEqual(@as(usize, 0), sink.bad_bytes);
    try std.testing.expect(sink.packets >= 2);
    try std.testing.expect(sink.max_len <= FastLedBatch.max_packet_bytes);
    for (0..8) |r| {
        for (0..8) |c_i| {
            const k: u8 = @intCast(r * 8 + c_i + 1);
            const t = fastLedPadTarget(@intCast(r), @intCast(c_i)).?;
            try std.testing.expectEqual(Rgb6{ .r = k & 63, .g = (k *% 3) & 63, .b = (k *% 7) & 63 }, sink.leds[t]);
        }
    }
    for (0..33) |i| {
        const k: u8 = @intCast(i + 1);
        const t = fastLedRingTarget(@intCast(i)).?;
        try std.testing.expectEqual(Rgb6{ .r = 63 - k, .g = k, .b = (k *% 2) & 63 }, sink.leds[t]);
    }
}
