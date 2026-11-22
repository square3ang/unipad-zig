//! Realistic Launchpad 128-entry RGB palette (Apollo Studio calibrated NovationPalette + perceptual LED-to-sRGB screen curve)
//! and Launchpad S red/green velocity map.
const std = @import("std");

/// Standard Novation Launchpad firmware 6-bit (0..63) RGB palette (16/32/63 steps; matches CoreFW & web-unipad `pallete.txt`).
const novation_r = [128]u8{
    0,  16, 32, 63, 63, 63, 32, 16, 63, 63, 32, 16, 63, 63, 32, 16,
    33, 20, 10, 5,  18, 0,  0,  0,  18, 0,  0,  0,  18, 0,  0,  0,
    18, 0,  0,  0,  18, 0,  0,  0,  18, 0,  0,  0,  11, 0,  0,  0,
    26, 11, 6,  3,  63, 63, 32, 16, 63, 63, 32, 16, 63, 37, 29, 8,
    0,  0,  0,  0,  0,  4,  31, 7,  63, 46, 43, 24, 3,  0,  0,  0,
    6,  22, 43, 10, 63, 33, 28, 0,  14, 21, 13, 22, 12, 26, 52, 63,
    63, 45, 35, 32, 14, 0,  3,  5,  5,  25, 32, 54, 53, 63, 39, 25,
    5,  54, 31, 38, 35, 15, 28, 55, 39, 13, 6,  1,  45, 15, 44, 18,
};
const novation_g = [128]u8{
    0,  16, 32, 63, 15, 0,  0,  0,  46, 15, 8,  4,  43, 63, 32, 16,
    63, 63, 32, 16, 63, 63, 32, 16, 63, 63, 32, 16, 63, 63, 32, 16,
    63, 63, 32, 16, 48, 41, 21, 11, 33, 21, 11, 6,  9,  0,  0,  0,
    13, 0,  0,  0,  15, 0,  0,  0,  16, 0,  0,  0,  3,  13, 20, 13,
    14, 18, 5,  0,  17, 0,  31, 7,  0,  63, 58, 63, 34, 63, 41, 10,
    0,  0,  6,  4,  12, 55, 63, 63, 63, 63, 63, 34, 20, 20, 7,  0,
    17, 41, 63, 22, 10, 18, 19, 5,  7,  14, 0,  16, 18, 47, 55, 44,
    5,  52, 58, 37, 25, 15, 28, 63, 0,  0,  51, 16, 43, 12, 20, 5,
};
const novation_b = [128]u8{
    0,  16, 32, 63, 15, 0,  0,  0,  26, 0,  0,  0,  11, 0,  0,  0,
    12, 0,  0,  0,  18, 0,  0,  0,  23, 6,  3,  1,  22, 21, 11, 6,
    45, 37, 18, 9,  63, 63, 32, 16, 63, 63, 32, 16, 63, 63, 32, 16,
    62, 63, 32, 16, 63, 63, 32, 16, 27, 20, 10, 5,  0,  0,  0,  1,
    0,  6,  27, 63, 19, 50, 31, 7,  0,  11, 1,  2,  0,  23, 63, 63,
    63, 63, 30, 0,  0,  1,  5,  0,  9,  27, 50, 63, 48, 57, 63, 22,
    0,  0,  0,  1,  0,  3,  8,  10, 22, 6,  0,  10, 4,  9,  11, 3,
    11, 26, 34, 63, 63, 15, 28, 63, 0,  0,  0,  0,  0,  0,  0,  0,
};

/// Per-channel perceptual LED-to-sRGB curve with frosted-silicone scatter and `#505050` ambient floor.
/// Avoids double-multiplying brightness (`val^2`) and lifts dark linear secondary channels (orange/blue/purple/dim steps).
fn led6ToScreenArgb(r6: u8, g6: u8, b6: u8) u32 {
    if (r6 == 0 and g6 == 0 and b6 == 0) return 0x00000000;
    const inv_gamma = 1.0 / 2.8;
    const sr: f64 = if (r6 > 0) std.math.pow(f64, @as(f64, @floatFromInt(r6)) / 63.0, inv_gamma) else 0.0;
    const sg: f64 = if (g6 > 0) std.math.pow(f64, @as(f64, @floatFromInt(g6)) / 63.0, inv_gamma) else 0.0;
    const sb: f64 = if (b6 > 0) std.math.pow(f64, @as(f64, @floatFromInt(b6)) / 63.0, inv_gamma) else 0.0;
    const lum = @max(sr, @max(sg, sb));

    // Frosted silicone scatter keeps whites neutral and gives blue/red/green real physical pad luminance.
    const rr = @min(1.0, sr + 0.16 * (lum - sr));
    const gg = @min(1.0, sg + 0.16 * (lum - sg) + 0.14 * @max(0.0, sb - @max(sr, sg)));
    const bb = @min(1.0, sb + 0.16 * (lum - sb));

    const bg = 80.0 / 255.0;
    const out_r: u32 = @intFromFloat(std.math.clamp(@round((rr + bg * (1.0 - lum) * (1.0 - rr)) * 255.0), 0.0, 255.0));
    const out_g: u32 = @intFromFloat(std.math.clamp(@round((gg + bg * (1.0 - lum) * (1.0 - gg)) * 255.0), 0.0, 255.0));
    const out_b: u32 = @intFromFloat(std.math.clamp(@round((bb + bg * (1.0 - lum) * (1.0 - bb)) * 255.0), 0.0, 255.0));
    return 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
}

/// On-screen 128-entry ARGB palette computed from the hardware 6-bit Novation LED table.
pub const argb: [128]u32 = blk: {
    @setEvalBranchQuota(20000);
    var out: [128]u32 = undefined;
    out[0] = 0x00000000;
    for (1..128) |i| {
        out[i] = led6ToScreenArgb(novation_r[i], novation_g[i], novation_b[i]);
    }
    break :blk out;
};

/// Red/green code table for Launchpad S / Mini MK1 / Mini MK2.
pub const scode: [128]u8 = .{
    0,  61, 62, 63, 1,  2,  3,  3, // 0..7
    21, 63, 62, 61, 53, 53, 53, 53, // 8..15
    53, 56, 56, 56, 56, 56, 56, 56, // 16..23
    56, 56, 56, 56, 53, 53, 53, 53, // 24..31
    53, 53, 53, 53, 53, 53, 53, 53, // 32..39
    53, 53, 53, 53, 53, 53, 53, 53, // 40..47
    53, 53, 53, 53, 37, 39, 39, 39, // 48..55
    37, 39, 39, 39, 3,  55, 57, 56, // 56..63
    56, 40, 53, 53, 53, 53, 53, 53, // 64..71
    3,  57, 57, 56, 56, 56, 53, 53, // 72..79
    53, 53, 53, 53, 58, 56, 56, 56, // 80..87
    56, 56, 56, 53, 53, 53, 47, 63, // 88..95
    59, 57, 57, 57, 57, 56, 56, 53, // 96..103
    53, 53, 3,  19, 53, 53, 53, 53, // 104..111
    53, 53, 53, 53, 53, 53, 53, 53, // 112..119
    3,  3,  56, 56, 57, 57, 57, 57, // 120..127
};

pub fn argbOf(velocity: u8) u32 {
    return argb[@min(velocity, 127)];
}

pub fn scodeOf(velocity: u8) u8 {
    return scode[@min(velocity, 127)];
}

pub fn novationRgb6(velocity: u8) [3]u8 {
    const i = @min(velocity, 127);
    return .{ novation_r[i], novation_g[i], novation_b[i] };
}

/// Closest Novation Launchpad RGB velocity for an arbitrary 0xAARRGGBB color.
pub fn nearestVelocity(col: u32) u8 {
    if ((col & 0x00FFFFFF) == 0) return 0;
    const r: i32 = @intCast((col >> 16) & 0xFF);
    const g: i32 = @intCast((col >> 8) & 0xFF);
    const b: i32 = @intCast(col & 0xFF);
    var best_idx: u8 = 3;
    var best_dist: i64 = std.math.maxInt(i64);
    for (1..128) |i| {
        const pr: i32 = @as(i32, novation_r[i]) * 4;
        const pg: i32 = @as(i32, novation_g[i]) * 4;
        const pb: i32 = @as(i32, novation_b[i]) * 4;
        const dr: i64 = r - pr;
        const dg: i64 = g - pg;
        const db: i64 = b - pb;
        const d = dr * dr + dg * dg + db * db;
        if (d < best_dist) {
            best_dist = d;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}

test "palette maps primary colors and perceptual LED curve cleanly" {
    try std.testing.expectEqual(@as(u8, 0), nearestVelocity(0xFF000000));
    try std.testing.expectEqual(@as(u8, 3), nearestVelocity(0xFFFFFFFF));
    const red = nearestVelocity(0xFFFF0000);
    try std.testing.expect(red == 5 or red == 72 or red == 120);
    // Neutral whites ramp cleanly and bright primaries stay vivid & luminous on screen
    try std.testing.expectEqual(@as(u32, 0xFFA8A8A8), argbOf(1));
    try std.testing.expectEqual(@as(u32, 0xFFCCCCCC), argbOf(2));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), argbOf(3));
    try std.testing.expectEqual(@as(u32, 0xFFFF2929), argbOf(5));
    try std.testing.expectEqual(@as(u32, 0xFF29FF29), argbOf(21));
    try std.testing.expectEqual(@as(u32, 0xFF294DFF), argbOf(45));
}
