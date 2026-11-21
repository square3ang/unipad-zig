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
