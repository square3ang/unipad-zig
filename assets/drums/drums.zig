//! Embedded Public Domain / CC0 / Unlicense / GPLv2+ drum one-shots used as fallback
//! when an Ableton Live project references uncollected Ableton Core Library drums.
const std = @import("std");

pub const DrumAsset = struct {
    name: []const u8,
    bytes: []const u8,
};

// LinnDrum LM-2 (Public Domain, via oramics/sampled)
const ld_kick = DrumAsset{ .name = "ld_kick.wav", .bytes = @embedFile("ld_kick.wav") };
const ld_snare = DrumAsset{ .name = "ld_snare-m.wav", .bytes = @embedFile("ld_snare-m.wav") };
const ld_clap = DrumAsset{ .name = "ld_clap.wav", .bytes = @embedFile("ld_clap.wav") };
const ld_ch = DrumAsset{ .name = "ld_hihat-closed.wav", .bytes = @embedFile("ld_hihat-closed.wav") };
const ld_oh = DrumAsset{ .name = "ld_hihat-open.wav", .bytes = @embedFile("ld_hihat-open.wav") };
const ld_crash = DrumAsset{ .name = "ld_crash.wav", .bytes = @embedFile("ld_crash.wav") };
const ld_ride = DrumAsset{ .name = "ld_ride.wav", .bytes = @embedFile("ld_ride.wav") };
const ld_tom = DrumAsset{ .name = "ld_tom-m.wav", .bytes = @embedFile("ld_tom-m.wav") };
const ld_rim = DrumAsset{ .name = "ld_stick-h.wav", .bytes = @embedFile("ld_stick-h.wav") };
const ld_cowb = DrumAsset{ .name = "ld_cowb.wav", .bytes = @embedFile("ld_cowb.wav") };
const ld_tamb = DrumAsset{ .name = "ld_tamb.wav", .bytes = @embedFile("ld_tamb.wav") };

// Roland TR-808 (CC0-1.0, Michael Fischer via tidalcycles/sounds-tr808-fischer)
const r808_kick_long = DrumAsset{ .name = "808_bd5050.wav", .bytes = @embedFile("808_bd5050.wav") };
const r808_kick_tight = DrumAsset{ .name = "808_bd5025.wav", .bytes = @embedFile("808_bd5025.wav") };
const r808_snare_hi = DrumAsset{ .name = "808_sd7575.wav", .bytes = @embedFile("808_sd7575.wav") };
const r808_snare_mid = DrumAsset{ .name = "808_sd5075.wav", .bytes = @embedFile("808_sd5075.wav") };
const r808_clap = DrumAsset{ .name = "808_cp.wav", .bytes = @embedFile("808_cp.wav") };
const r808_ch = DrumAsset{ .name = "808_ch.wav", .bytes = @embedFile("808_ch.wav") };
const r808_oh = DrumAsset{ .name = "808_oh.wav", .bytes = @embedFile("808_oh.wav") };
const r808_cowb = DrumAsset{ .name = "808_cb.wav", .bytes = @embedFile("808_cb.wav") };
const r808_rim = DrumAsset{ .name = "808_rs.wav", .bytes = @embedFile("808_rs.wav") };

// Roland TR-909 (Royalty-free / MIT repo, via averagenative/0x808)
const r909_kick = DrumAsset{ .name = "909_kick.wav", .bytes = @embedFile("909_kick.wav") };
const r909_snare = DrumAsset{ .name = "909_snare.wav", .bytes = @embedFile("909_snare.wav") };
const r909_snare_short = DrumAsset{ .name = "909_snare_short.wav", .bytes = @embedFile("909_snare_short.wav") };
const r909_clap = DrumAsset{ .name = "909_clap.wav", .bytes = @embedFile("909_clap.wav") };
const r909_ch = DrumAsset{ .name = "909_ch.wav", .bytes = @embedFile("909_ch.wav") };
const r909_oh = DrumAsset{ .name = "909_oh.wav", .bytes = @embedFile("909_oh.wav") };
const r909_rim = DrumAsset{ .name = "909_rim.wav", .bytes = @embedFile("909_rim.wav") };
const r909_tom_lo = DrumAsset{ .name = "909_tom_l.wav", .bytes = @embedFile("909_tom_l.wav") };
const r909_tom_mid = DrumAsset{ .name = "909_tom_m.wav", .bytes = @embedFile("909_tom_m.wav") };
const r909_tom_hi = DrumAsset{ .name = "909_tom_h.wav", .bytes = @embedFile("909_tom_h.wav") };
const r909_cymbal = DrumAsset{ .name = "909_cymbal.wav", .bytes = @embedFile("909_cymbal.wav") };
const r909_ride = DrumAsset{ .name = "909_ride.wav", .bytes = @embedFile("909_ride.wav") };

// Electronic punchy one-shots (Unlicense, via tidalcycles/uzu-drumkit)
const uzu_kick = DrumAsset{ .name = "uzu_bd10.wav", .bytes = @embedFile("uzu_bd10.wav") };
const uzu_snare = DrumAsset{ .name = "uzu_sd11.wav", .bytes = @embedFile("uzu_sd11.wav") };

// LMMS drums (GPL-2.0-or-later, via LMMS/lmms)
const lmms_kick = DrumAsset{ .name = "lmms_kick01.ogg", .bytes = @embedFile("lmms_kick01.ogg") };
const lmms_kick_808 = DrumAsset{ .name = "lmms_kick_hiphop01.ogg", .bytes = @embedFile("lmms_kick_hiphop01.ogg") };
const lmms_snare = DrumAsset{ .name = "lmms_snare01.ogg", .bytes = @embedFile("lmms_snare01.ogg") };
const lmms_clap = DrumAsset{ .name = "lmms_clap01.ogg", .bytes = @embedFile("lmms_clap01.ogg") };
const lmms_ch = DrumAsset{ .name = "lmms_hihat_closed01.ogg", .bytes = @embedFile("lmms_hihat_closed01.ogg") };
const lmms_oh = DrumAsset{ .name = "lmms_hihat_opened01.ogg", .bytes = @embedFile("lmms_hihat_opened01.ogg") };
const lmms_crash = DrumAsset{ .name = "lmms_crash01.ogg", .bytes = @embedFile("lmms_crash01.ogg") };
const lmms_ride = DrumAsset{ .name = "lmms_ride01.ogg", .bytes = @embedFile("lmms_ride01.ogg") };
const lmms_tom_lo = DrumAsset{ .name = "lmms_tom_low01.ogg", .bytes = @embedFile("lmms_tom_low01.ogg") };
const lmms_tom_mid = DrumAsset{ .name = "lmms_tom_mid01.ogg", .bytes = @embedFile("lmms_tom_mid01.ogg") };
const lmms_tom_hi = DrumAsset{ .name = "lmms_tom_hi01.ogg", .bytes = @embedFile("lmms_tom_hi01.ogg") };
const lmms_rim = DrumAsset{ .name = "lmms_rim01.ogg", .bytes = @embedFile("lmms_rim01.ogg") };
const lmms_shaker = DrumAsset{ .name = "lmms_shaker01.ogg", .bytes = @embedFile("lmms_shaker01.ogg") };

pub const all_assets = [_]DrumAsset{
    ld_kick,        ld_snare,        ld_clap,         ld_ch,        ld_oh,         ld_crash,
    ld_ride,        ld_tom,          ld_rim,          ld_cowb,      ld_tamb,       r808_kick_long,
    r808_kick_tight, r808_snare_hi,  r808_snare_mid,  r808_clap,    r808_ch,       r808_oh,
    r808_cowb,      r808_rim,        r909_kick,       r909_snare,   r909_snare_short, r909_clap,
    r909_ch,        r909_oh,         r909_rim,        r909_tom_lo,  r909_tom_mid,  r909_tom_hi,
    r909_cymbal,    r909_ride,       uzu_kick,        uzu_snare,    lmms_kick,     lmms_kick_808,
    lmms_snare,     lmms_clap,       lmms_ch,         lmms_oh,      lmms_crash,    lmms_ride,
    lmms_tom_lo,    lmms_tom_mid,    lmms_tom_hi,     lmms_rim,     lmms_shaker,
};

pub fn lookup(rel_path: []const u8, file_name: []const u8) ?DrumAsset {
    const is_ld = has(rel_path, file_name, "-ld") or has(rel_path, file_name, "_ld") or has(rel_path, file_name, "linn");
    const is_909 = has(rel_path, file_name, "909") or has(rel_path, file_name, "electro") or has(rel_path, file_name, "hard");
    const is_808 = has(rel_path, file_name, "808") or has(rel_path, file_name, "sub") or has(rel_path, file_name, "hiphop");
    const is_hi_tune = has(rel_path, file_name, "tune7") or has(rel_path, file_name, "tune8") or
        has(rel_path, file_name, "tune9") or has(rel_path, file_name, "tune10") or has(rel_path, file_name, "high");

    if (has(rel_path, file_name, "kick") or has(rel_path, file_name, "bd")) {
        if (is_ld) return ld_kick;
        if (is_909) return r909_kick;
        if (is_808) return if (has(rel_path, file_name, "short")) r808_kick_tight else r808_kick_long;
        return lmms_kick;
    }
    if (has(rel_path, file_name, "snare") or has(rel_path, file_name, "sd")) {
        if (is_ld) return ld_snare;
        if (is_909) return if (has(rel_path, file_name, "short")) r909_snare_short else r909_snare;
        if (is_808) return if (is_hi_tune) r808_snare_hi else r808_snare_mid;
        return uzu_snare;
    }
    if (has(rel_path, file_name, "clap") or has(rel_path, file_name, "cp")) {
        if (is_ld) return ld_clap;
        if (is_909) return r909_clap;
        if (is_808) return r808_clap;
        return lmms_clap;
    }
    if (has(rel_path, file_name, "hihat") or has(rel_path, file_name, "hat") or has(rel_path, file_name, "hh")) {
        const open = has(rel_path, file_name, "open") or has(rel_path, file_name, "oh");
        if (is_ld) return if (open) ld_oh else ld_ch;
        if (is_909) return if (open) r909_oh else r909_ch;
        if (is_808) return if (open) r808_oh else r808_ch;
        return if (open) lmms_oh else lmms_ch;
    }
    if (has(rel_path, file_name, "crash") or has(rel_path, file_name, "cymbal") or has(rel_path, file_name, "cym")) {
        if (is_ld) return ld_crash;
        if (is_909) return r909_cymbal;
        return lmms_crash;
    }
    if (has(rel_path, file_name, "ride")) {
        if (is_ld) return ld_ride;
        if (is_909) return r909_ride;
        return lmms_ride;
    }
    if (has(rel_path, file_name, "tom")) {
        if (is_ld) return ld_tom;
        if (is_909) {
            if (has(rel_path, file_name, "hi") or has(rel_path, file_name, "high")) return r909_tom_hi;
            if (has(rel_path, file_name, "lo") or has(rel_path, file_name, "low")) return r909_tom_lo;
            return r909_tom_mid;
        }
        if (has(rel_path, file_name, "hi") or has(rel_path, file_name, "high")) return lmms_tom_hi;
        if (has(rel_path, file_name, "lo") or has(rel_path, file_name, "low")) return lmms_tom_lo;
        return lmms_tom_mid;
    }
    if (has(rel_path, file_name, "rim") or has(rel_path, file_name, "stick")) {
        if (is_ld) return ld_rim;
        if (is_909) return r909_rim;
        if (is_808) return r808_rim;
        return lmms_rim;
    }
    if (has(rel_path, file_name, "cowb") or has(rel_path, file_name, "bell")) {
        return if (is_808) r808_cowb else ld_cowb;
    }
    if (has(rel_path, file_name, "tamb")) {
        return ld_tamb;
    }
    if (has(rel_path, file_name, "shaker") or has(rel_path, file_name, "cabasa") or has(rel_path, file_name, "perc")) {
        return lmms_shaker;
    }
    return null;
}

fn has(a: []const u8, b: []const u8, needle: []const u8) bool {
    return containsIgnoreCase(a, needle) or containsIgnoreCase(b, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
