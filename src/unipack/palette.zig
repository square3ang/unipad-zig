//! Official UniPad 128-entry ARGB palette and Launchpad S red/green velocity map.
const std = @import("std");

pub const argb: [128]u32 = .{
    0x00000000, // 0
    0x77fafafa, // 1
    0xAAfafafa, // 2
    0xFFfafafa, // 3
    0xFFf8bbd0,
    0xFFef5350, // 5
    0xFFe57373,
    0xFFef9a9a,

    0xFFfff3e0,
    0xFFffa726,
    0xFFffb960, // 10
    0xFFffcc80,
    0xFFffe0b2,
    0xFFffee58,
    0xFFfff59d,
    0xFFfff9c4,

    0xFFdcedc8,
    0xFF8bc34a, // 17
    0xFFaed581,
    0xFFbfdf9f,
    0xFF5ee2b0,
    0xFF00ce3c,
    0xFF00ba43,
    0xFF119c3f,

    0xFF57ecc1,
    0xFF00e864,
    0xFF00e05c,
    0xFF00d545,
    0xFF7afddd,
    0xFF00e4c5,
    0xFF00e0b2,
    0xFF01eec6,

    0xFF49efef,
    0xFF00e7d8,
    0xFF00e5d1,
    0xFF01efde,
    0xFF6addff,
    0xFF00dafe,
    0xFF01d6ff,
    0xFF08acdc,

    0xFF73cefe,
    0xFF0d9bf7,
    0xFF148de4,
    0xFF2a77c9,
    0xFF8693ff,
    0xFF2196f3, // 45
    0xFF4668f6,
    0xFF4153dc,

    0xFFb095ff,
    0xFF8453fd,
    0xFF634acd,
    0xFF5749c5,
    0xFFffb7ff,
    0xFFe863fb,
    0xFFd655ed,
    0xFFd14fe9,

    0xFFfc99e3,
    0xFFe736c2,
    0xFFe52fbe,
    0xFFe334b6,
    0xFFed353e,
    0xFFffa726, // 61
    0xFFf4df0b,
    0xFF8bc34a, // 63

    0xFF5cd100, // 64
    0xFF00d29e,
    0xFF2388ff,
    0xFF3669fd,
    0xFF00b4d0,
    0xFF475cdc,
    0xDDfafafa, // 70
    0xCCfafafa, // 71

    0xFFf72737,
    0xFFd2ea7b,
    0xFFc8df10,
    0xFF7fe422,
    0xFF00c931,
    0xFF00d7a6,
    0xFF00d8fc,
    0xFF0b9bfc,

    0xFF585cf5,
    0xFFac59f0,
    0xFFd980dc,
    0xFFb8814a,
    0xFFff9800,
    0xFFabdf22,
    0xFF9ee154,
    0xFF66bb6a, // 87

    0xFF3bda47,
    0xFF6fdeb9,
    0xFF27dbda,
    0xFF9cc8fd,
    0xFF79b8f7,
    0xFFafafef,
    0xFFd580eb,
    0xFFf74fca,

    0xFFea8a1f,
    0xFFdbdb08,
    0xFF9cd60d,
    0xFFf3d335,
    0xFFc8af41,
    0xFF00ca69,
    0xFF24d2b0,
    0xFF757ebe,

    0xFF5388db,
    0xFFe5c5a6,
    0xFFe93b3b,
    0xFFf9a2a1,
    0xFFed9c65,
    0xFFe1ca72,
    0xFFb8da78,
    0xFF98d52c,

    0xFF626cbd,
    0xFFcac8a0,
    0xFF90d4c2,
    0xFFceddfe,
    0xFFbeccf7,
    0x55fafafa, // 117
    0x77fafafa, // 118
    0xAAfafafa, // 119

    0xFFfe1624,
    0xFFcd2724,
    0xFF9ccc65, // 122
    0xFF009c1b,
    0xFFffff00, // 124
    0xFFbeb212,
    0xFFf5d01d, // 126
    0xFFe37829,
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

/// Novation Launchpad RGB hardware 6-bit (0..63) palette (Pro Mk3 / X / Mini Mk3).
const novation_r = [128]u8{
    0,  15, 31, 63, 63, 63, 31, 15, 63, 63, 31, 15, 63, 63, 31, 15,
    31, 19, 11, 5,  19, 0,  0,  0,  19, 0,  0,  0,  19, 0,  0,  0,
    19, 0,  0,  0,  19, 0,  0,  0,  19, 0,  0,  0,  11, 0,  0,  0,
    23, 11, 5,  3,  63, 63, 31, 15, 63, 63, 31, 15, 63, 39, 31, 11,
    0,  0,  0,  0,  0,  7,  23, 7,  63, 47, 43, 23, 3,  0,  0,  0,
    7,  23, 43, 11, 63, 31, 27, 0,  15, 23, 15, 23, 11, 27, 55, 63,
    63, 47, 35, 31, 15, 0,  3,  5,  5,  23, 31, 55, 55, 63, 39, 27,
    5,  55, 31, 39, 35, 15, 27, 55, 39, 13, 5,  0,  47, 15, 43, 19,
};
const novation_g = [128]u8{
    0,  15, 31, 63, 15, 0,  0,  0,  47, 15, 7,  3,  43, 63, 31, 15,
    63, 63, 31, 15, 63, 63, 31, 15, 63, 63, 31, 15, 63, 63, 31, 15,
    63, 63, 31, 15, 47, 43, 21, 11, 31, 21, 11, 5,  7,  0,  0,  0,
    15, 0,  0,  0,  15, 0,  0,  0,  15, 0,  0,  0,  3,  15, 19, 11,
    15, 15, 7,  0,  15, 0,  15, 3,  0,  63, 59, 63, 31, 63, 39, 11,
    0,  0,  7,  3,  11, 55, 63, 63, 63, 59, 63, 35, 19, 19, 7,  0,
    19, 43, 63, 23, 11, 17, 19, 5,  7,  13, 0,  15, 17, 47, 55, 43,
    5,  55, 59, 39, 27, 15, 27, 63, 0,  0,  51, 15, 43, 11, 19, 3,
};
const novation_b = [128]u8{
    0,  15, 31, 63, 15, 0,  0,  0,  27, 0,  0,  0,  11, 0,  0,  0,
    11, 0,  0,  0,  15, 0,  0,  0,  19, 7,  3,  1,  23, 23, 11, 5,
    47, 39, 19, 9,  63, 63, 31, 15, 63, 63, 31, 15, 63, 63, 31, 15,
    63, 63, 31, 15, 63, 63, 31, 15, 27, 19, 11, 7,  0,  0,  0,  0,
    0,  7,  27, 63, 15, 47, 19, 5,  0,  11, 0,  0,  0,  23, 63, 63,
    63, 59, 31, 0,  0,  0,  7,  0,  11, 27, 51, 63, 51, 55, 63, 23,
    0,  0,  0,  0,  0,  3,  7,  11, 23, 5,  0,  11, 3,  7,  11, 3,
    11, 27, 35, 63, 63, 15, 27, 63, 0,  0,  0,  0,  0,  0,  0,  0,
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
        const p = argb[i];
        const pa: i32 = @intCast((p >> 24) & 0xFF);
        const pr: i32 = @divTrunc(@as(i32, @intCast((p >> 16) & 0xFF)) * pa, 255);
        const pg: i32 = @divTrunc(@as(i32, @intCast((p >> 8) & 0xFF)) * pa, 255);
        const pb: i32 = @divTrunc(@as(i32, @intCast(p & 0xFF)) * pa, 255);
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

test "palette nearestVelocity maps primary colors sensibly" {
    try std.testing.expectEqual(@as(u8, 0), nearestVelocity(0xFF000000));
    try std.testing.expectEqual(@as(u8, 3), nearestVelocity(0xFFFFFFFF));
    const red = nearestVelocity(0xFFFF0000);
    try std.testing.expect(red == 5 or red == 72 or red == 120);
}
