//! Pure-Zig Max for Live (M4L) device identification, blob decoding, lightshow/sample adapters,
//! and custom palette parsing for the Ableton Live -> UniPack converter.
//!
//! Compiles identically on desktop and `wasm32-freestanding` (zero C / libc dependencies).
//!
//! Ported from and inspired by Amethyst (`https://github.com/anthonyhfm/Amethyst`, GPL-3.0).
//! Both projects are licensed under GPL-3.0.
const std = @import("std");
const palette = @import("palette.zig");
const types = @import("types.zig");

pub const VirtualFile = types.VirtualFile;

pub const NoteLayout = enum { user1, programmer };

pub const SimNote = struct {
    start_ms: f64,
    dur_ms: f64,
    note: u8,
    vel: u8,
    color_override: u32 = 0, // 0 = resolve via palette(vel); non-zero = explicit 0xFFRRGGBB
    layer: i16 = 0,
    loop: bool = false,
    infinite: bool = false,
};

pub const MxParamKind = enum(u8) { float, int, enum_v };

pub const MxParam = struct {
    index: u16 = 0,
    kind: MxParamKind = .float,
    name: []const u8 = "",
    value: f64 = 0.0,
};

pub const MxFileDrop = struct {
    name: []const u8 = "",
    rel_path: []const u8 = "",
    file_name: []const u8 = "",
};

pub const MxDeviceData = struct {
    on: bool = true,
    lom_id: u32 = 0,
    patch_rel: []const u8 = "",
    patch_name: []const u8 = "",
    blob: []const u8 = "",
    params: []const MxParam = &.{},
    drops: []const MxFileDrop = &.{},
    // Cached/legacy direct drop fallback (first drop)
    mid_rel: []const u8 = "",
    mid_name: []const u8 = "",
};

pub const MxDeviceKind = enum(u8) {
    unknown,
    midi_ext,
    midi_fire,
    midi_ext_multi_lights,
    midi_launcher,
    midi_launcher_pro,
    lightspeed,
    cycle_lights,
    cycle_samples,
    supersonic,
    resonator1,
    resonator2,
    resonator3,
    resonator301,
    resonator4,
    twist,
    flip,
    iris,
    delay,
    infinity,
    depths_selector,
    depths_mixer,
    grid_filter,
    midi_transform,
    set_notes,
    multi_outbreak,
    multi_kaskobi,
    multi_reset,
    wormhole,
    wormhole_lite,
    blackhole,
    auto_page,
    page_switcher,
};

pub const IdentifiedMx = struct {
    kind: MxDeviceKind = .unknown,
    hash: [32]u8 = @splat(0),
    has_hash: bool = false,
};

pub const max_sim_notes: usize = 32768;

// ============================================================================
// Coordinate & Palette Helpers
// ============================================================================

/// Converts Ableton MIDI note to 0-based UniPack (row, col) with row 0 = top, col 0 = left.
pub fn midiNoteToXY(layout: NoteLayout, note: u8) ?[2]u8 {
    switch (layout) {
        .user1 => {
            if (note < 36 or note > 99) return null;
            const rel = note - 36;
            const half: u8 = rel / 32; // 0 = left 4 cols, 1 = right 4 cols
            const sub = rel % 32;
            const row_from_bottom = sub / 4; // 0..7
            const col_in_half = sub % 4; // 0..3
            return .{ 7 - row_from_bottom, half * 4 + col_in_half };
        },
        .programmer => {
            if (note < 11 or note > 88) return null;
            const r = note / 10;
            const col = note % 10;
            if (r < 1 or r > 8 or col < 1 or col > 8) return null;
            return .{ 8 - r, col - 1 };
        },
    }
}

pub fn xyToMidiNote(layout: NoteLayout, row: u8, col: u8) u8 {
    switch (layout) {
        .user1 => {
            const half: u8 = col / 4;
            const col_in_half: u8 = col % 4;
            const row_from_bottom: u8 = 7 - row;
            return 36 + half * 32 + row_from_bottom * 4 + col_in_half;
        },
        .programmer => {
            return (8 - row) * 10 + (col + 1);
        },
    }
}

/// Converts a Launchpad Programmer Mode XY index (`11..88` grid, `1..8`/`10..80`/`19..89`/`91..98` ring)
/// to a MIDI note in the given layout.
pub fn progIndexToMidiNote(layout: NoteLayout, index: u8) ?u8 {
    if (index == 0 or index > 99) return null;
    const x: u8 = index % 10; // 1..8 = cols 0..7, 0 = left, 9 = right
    const y_from_bottom: u8 = index / 10; // 1..8 = rows 7..0, 0 = bottom, 9 = top
    if (x >= 1 and x <= 8 and y_from_bottom >= 1 and y_from_bottom <= 8) {
        return xyToMidiNote(layout, 8 - y_from_bottom, x - 1);
    }
    if (layout == .programmer) return index;
    // User 1 ring note mapping
    if (y_from_bottom == 9 and x >= 1 and x <= 8) return 28 + (x - 1); // top
    if (x == 9 and y_from_bottom >= 1 and y_from_bottom <= 8) return 100 + (8 - y_from_bottom); // right
    if (y_from_bottom == 0 and x >= 1 and x <= 8) return 108 + (8 - x); // bottom
    if (x == 0 and y_from_bottom >= 1 and y_from_bottom <= 8) return 116 + (y_from_bottom - 1); // left
    if (index == 99) return 27; // logo
    return null;
}

/// Parses a Max-format custom Launchpad palette file (`idx, r g b;` with 0..63 RGB channels).
/// Returns null if the buffer does not look like a valid palette file.
pub fn parsePaletteFile(bytes: []const u8) ?[128]u32 {
    var table: [128]u32 = undefined;
    for (0..128) |i| table[i] = palette.argbOf(@intCast(i));

    var valid_count: usize = 0;
    var it = std.mem.splitAny(u8, bytes, "\r\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t;");
        if (line.len == 0) continue;
        const comma = std.mem.indexOfScalar(u8, line, ',') orelse continue;
        const idx_s = std.mem.trim(u8, line[0..comma], " \t");
        const idx = std.fmt.parseInt(usize, idx_s, 10) catch continue;
        if (idx >= 128) continue;

        var rgb_it = std.mem.tokenizeAny(u8, line[comma + 1 ..], " \t;");
        const r_s = rgb_it.next() orelse continue;
        const g_s = rgb_it.next() orelse continue;
        const b_s = rgb_it.next() orelse continue;
        const r63 = std.fmt.parseInt(u32, r_s, 10) catch continue;
        const g63 = std.fmt.parseInt(u32, g_s, 10) catch continue;
        const b63 = std.fmt.parseInt(u32, b_s, 10) catch continue;
        if (r63 > 63 or g63 > 63 or b63 > 63) continue;

        const r8: u32 = (r63 * 255 + 31) / 63;
        const g8: u32 = (g63 * 255 + 31) / 63;
        const b8: u32 = (b63 * 255 + 31) / 63;
        table[idx] = 0xFF000000 | (r8 << 16) | (g8 << 8) | b8;
        valid_count += 1;
    }
    if (valid_count < 8) return null;
    return table;
}

/// Scans project virtual files for a custom palette file (`.txt` / `.pal` / `palette`).
pub fn findCustomPalette(files: []const VirtualFile) ?[128]u32 {
    for (files) |f| {
        if (f.bytes.len < 64 or f.bytes.len > 65536) continue;
        const base = basenameOf(f.rel_path);
        const is_pal_ext = endsWithIgnoreCase(base, ".pal") or endsWithIgnoreCase(base, ".txt");
        if (!is_pal_ext) continue;
        // Prefer explicitly named palette files or any file matching strict Max `idx, r g b;` syntax
        if (parsePaletteFile(f.bytes)) |tbl| return tbl;
    }
    return null;
}

// ============================================================================
// MD5 Identification Table (Amethyst GPL-3.0 Hash Registry)
// ============================================================================

const hash_table = std.StaticStringMap(MxDeviceKind).initComptime(.{
    // Outbreak Twist
    .{ "bd5d1649fed009d5399a9e8e84a0b036", .twist },
    .{ "1e55e95bbcbd08f6f6739b235b5da30b", .twist },
    .{ "cc9e206793622e0a03041c05ec7ed8ca", .twist },
    .{ "306012649f1a5eca6e6b4e5dca3f6159", .twist },
    .{ "a6d42dc12c6529eb4ff4be9f6a0cef71", .twist },
    .{ "fe1b005361b8f099ca487aae25cc16d6", .twist },
    .{ "fe575828d488675752a087c80401af63", .twist },
    .{ "e8726f6b3088125c4c6aaff083b1730b", .twist },
    .{ "9a7f0ac3bc4d354c2a560427b6093f87", .twist },

    // Nyrk Blackhole
    .{ "4dad8b910bb0747a8839961bc6354a1a", .blackhole },

    // Outbreak Delay
    .{ "14783922241a74cd4da95beed0f57b95", .delay },
    .{ "349064d3d33e7ed2c39d766f308aa023", .delay },

    // Outbreak Flip
    .{ "4ca220e9b84d740854eb8e1b00843265", .flip },
    .{ "1140e1f12d76876e36441b17f9b0f189", .flip },
    .{ "8f88406409ddaf7dd8413e1b5e01f859", .flip },
    .{ "e15e0b9e248adfeeb57d7f9c54a978d8", .flip },
    .{ "dfb2c1c6968c8547b26efd31c69dd555", .flip },
    .{ "620a46951d419c62150da25467ec044b", .flip },
    .{ "811c3c410fce75959c8ab17220186701", .flip },

    // Outbreak Iris
    .{ "4ab1f1c29a3ac9e447756a9d075c2a6b", .iris },
    .{ "4feeb78db6367007b1badf8f9d2c1cae", .iris },
    .{ "bcfb325a212a70bdd0acdbf740114389", .iris },
    .{ "a591e409a908e4bd1898152222cc8336", .iris },

    // Outbreak DepthsSelector
    .{ "7bd5bf9ea8431c5697b226aa906d87ac", .depths_selector },
    .{ "d56c1f4e81d50a7bfd6481099848e48a", .depths_selector },
    .{ "af7c8717c232587ecea9ee2105eca17c", .depths_selector },

    // Outbreak Infinity
    .{ "07b41f57975c3f6b65b37be548c23377", .infinity },
    .{ "db42168ef06e75ab599a30570c565b20", .infinity },
    .{ "5ef8dd91805de9f50000565f21d1485c", .infinity },
    .{ "4daa43e6e4704693794cb14a33cc00fa", .infinity },

    // Kaskobi Wormhole Lite
    .{ "b587108a297a3eb744172735c5d3f064", .wormhole_lite },
    .{ "9f50358372279f946cae0fdac0cfbf56", .wormhole_lite },

    // Kaskobi Page Switcher
    .{ "220a5d8ae9bd63f21c8292c03774ef90", .page_switcher },
    .{ "32b6bec96552a6e40f6743787a20b9df", .page_switcher },
    .{ "1848f6da9155cc90ecd5e22d4b43c217", .page_switcher },
    .{ "8e44fe875327f2b1bae5ff645c6b289b", .page_switcher },
    .{ "feecaed62c2637a73325446a1ed1e25e", .page_switcher },

    // Kaskobi Resonator 1 / 2 / 3 / 3.0.1 / 4
    .{ "4bd554ebb0ee0536dee1ab7a9875fc20", .resonator1 },
    .{ "d8c48c67824319295bb5bf7abda47f27", .resonator2 },
    .{ "6257e885f06b1c1fb6258b1066497244", .resonator3 },
    .{ "72bbd3837984d7eb1a881116c5ab5fe6", .resonator301 },
    .{ "8bf54c465707076e50119269289e23be", .resonator4 },

    // Kaskobi Generic MIDI Extension (MIDIext 1.x - 5.x)
    .{ "2491c3c841b70b7c9765db8e4defdfff", .midi_ext },
    .{ "8131f56b0fed3013999374d7e27b0ae0", .midi_ext },
    .{ "433a3efd3c017d799519fc80ec31a53d", .midi_ext },
    .{ "e10191145ac3fcc5c9de4bc5e6997764", .midi_ext },
    .{ "7295b9ab0878170b1080e2a89feed177", .midi_ext },
    .{ "7aed2a19a3776486492e9abc1307d8ba", .midi_ext },
    .{ "031356ce98ba9104607ea3e57c8fd37e", .midi_ext },
    .{ "8b7dc60359dadae0ef6755eddcbe0185", .midi_ext },
    .{ "25a0f03868c45af4d06bcead0a1bc6ce", .midi_ext },
    .{ "494a1455eac528aee9d94055dcdb4463", .midi_ext },
    .{ "aacfc91a06f6ce784ace184ad436da47", .midi_ext },
    .{ "e4a51582c69996d40a7dfb27c9c4a948", .midi_ext },
    .{ "247590e4be0b51ce925bba2aa1d2701d", .midi_ext },
    .{ "6557d723e39156749aa1b55e38c53995", .midi_ext },
    .{ "fa3f0f6b3af43ab4bd754010124f9dc7", .midi_ext },
    .{ "4b74eea1e5ee0db42171418717c02561", .midi_ext },
    .{ "4dd48ac60e858928fff89a28865ce735", .midi_ext },
    .{ "f886850f9aba5cf8ae497f3e58231616", .midi_ext },
    .{ "908c82a8eca07a56eaa35c1b6c6f72be", .midi_ext },
    .{ "5aa613617ae0b0e24cbe715dbe3960e2", .midi_ext },
    .{ "f004d757e3910cc81b317a55e4dd6263", .midi_ext },
    .{ "d53dcb292a173ab7853183f3cab7620c", .midi_ext },
    .{ "ffd72babd9b6051d8b3b0a4a5602d5fe", .midi_ext },
    .{ "6996d81ae12c12a7d1d2a45548bcd45e", .midi_ext },

    // Kaskobi MidiExt Multi Lights & MidiFire
    .{ "4957d3dcbbb5b6fc53ed00f032cc9b24", .midi_ext_multi_lights },
    .{ "f2504fe314d81dcc9b57e2466a157033", .midi_fire },

    // Kaskobi MidiLauncher / MidiLauncher Pro
    .{ "2ef098a53fe4e9a4b035588561080343", .midi_launcher },
    .{ "f135067227057b08f8d2d2ae66a22f8d", .midi_launcher },
    .{ "2d5d5420fea42678807d1569ce08b182", .midi_launcher_pro },
    .{ "a114e5d1a7710271501649668c14f1ab", .midi_launcher_pro },
    .{ "34bcbf910a9985951a0dd6ead9f8fc4c", .midi_launcher_pro },

    // Dovitate Lightspeed / CycleLights / CycleSamples / Supersonic
    .{ "aa743dda3d25332ecf3ae084eb7cbd30", .lightspeed },
    .{ "93c44e78923b4b220be4111f47d7b27e", .lightspeed },
    .{ "93b3690b7e7036ab0ba662e589d7ef37", .cycle_lights },
    .{ "827910972f4410bd36c2a7eef029a2d7", .cycle_samples },
    .{ "a65f124fa2b4df604144ec3bb78df008", .supersonic },

    // Kaskobi MidiTransform / SetNotes / MultiReset / GridFilter / AutoPage
    .{ "b3ff29c822cdd8573e901042f68900b3", .midi_transform },
    .{ "24a40fbc9106a03e7cb2025754a2e8dc", .set_notes },
    .{ "6a03db17df474d5d526e32d4efc70eae", .multi_reset },
    .{ "168cda682434227f77d52824814c8235", .grid_filter },
    .{ "6a7252ed039bba60831038cbc21dbdd7", .grid_filter },
    .{ "c328c055ae8daf2d9a4e2c0346bcc2ee", .auto_page },
    .{ "f6c14612b30196941ee3f19b056b62b2", .auto_page },

    // Nev Wormhole
    .{ "3d3de9b05506f279ad6cfe14d26e0084", .wormhole },
    .{ "7361d4c4b12bea802d369a0bb5ba7c68", .wormhole },

    // Outbreak Multi (MultiPluginHashes.MULTI_HASHES)
    .{ "8abe9e549be11285b32c08e119f884ea", .multi_outbreak },
    .{ "611d9b27e24b51cc4d283bcd7de2537f", .multi_outbreak },
    .{ "fc21b36fc3255cac7707b8c38091ca29", .multi_outbreak },
    .{ "27fc73ba4c082007e52a87451d123fdb", .multi_outbreak },
    .{ "d55d163e9405d92bf02e82aee609670c", .multi_outbreak },
    .{ "0a73bde117f65912605eded5f46d5937", .multi_outbreak },
    .{ "56dfabc2d4ddb1f2f46170f9a1e94d63", .multi_outbreak },
    .{ "0378e9997fda45ba6a0f8253098ba71e", .multi_outbreak },
    .{ "0effdb49e361a90526c09889e473ea77", .multi_outbreak },
    .{ "ead00175034274ed657cfdf66dbf40f3", .multi_outbreak },

    // Kaskobi MultiEffect (MultiPluginHashes.KASKOBI_MULTI_HASHES)
    .{ "724287b36492668526a597562d7732c6", .multi_kaskobi },
    .{ "2e993c63826a4b737b21479f58a7238d", .multi_kaskobi },
    .{ "d098a20a1a2c1165032ece71fd9297ad", .multi_kaskobi },
    .{ "1c81406d3fcf0183005fbe0077a420b7", .multi_kaskobi },
    .{ "c861cfd71c9b0ddce3df83b3f1099ed0", .multi_kaskobi },
    .{ "648e714d3f1d833e2b5856ed2b43c525", .multi_kaskobi },
});

pub const AmxdHashCache = struct {
    by_path: std.StringHashMapUnmanaged([32]u8) = .empty,

    pub fn getHash(self: *AmxdHashCache, a: std.mem.Allocator, files: []const VirtualFile, rel_path: []const u8, file_name: []const u8) ?[32]u8 {
        const key = if (file_name.len > 0) file_name else basenameOf(rel_path);
        if (key.len == 0) return null;
        if (self.by_path.get(key)) |h| return h;

        const vf = findProjectFile(files, rel_path, file_name) orelse return null;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(vf.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const key_copy = a.dupe(u8, key) catch return hex;
        self.by_path.put(a, key_copy, hex) catch {};
        return hex;
    }
};

pub fn identifyMxDevice(
    a: std.mem.Allocator,
    cache: *AmxdHashCache,
    files: []const VirtualFile,
    mx: MxDeviceData,
) IdentifiedMx {
    var out: IdentifiedMx = .{};
    if (cache.getHash(a, files, mx.patch_rel, mx.patch_name)) |hex| {
        out.hash = hex;
        out.has_hash = true;
        if (hash_table.get(&hex)) |k| {
            out.kind = k;
            return out;
        }
    }

    // Filename & blob-structure fallback (handles uncollected .amxd devices too!)
    const raw_name = if (mx.patch_name.len > 0) mx.patch_name else basenameOf(mx.patch_rel);
    if (raw_name.len > 0) {
        if (containsIgnoreCase(raw_name, "depths mixer")) {
            out.kind = .depths_mixer;
            return out;
        }
        if (containsIgnoreCase(raw_name, "depths selector") or containsIgnoreCase(raw_name, "depths_selector")) {
            out.kind = .depths_selector;
            return out;
        }
        if (containsIgnoreCase(raw_name, "midifire")) {
            out.kind = .midi_fire;
            return out;
        }
        if (containsIgnoreCase(raw_name, "midilauncher pro") or containsIgnoreCase(raw_name, "midi launcher pro")) {
            out.kind = .midi_launcher_pro;
            return out;
        }
        if (containsIgnoreCase(raw_name, "midilauncher") or containsIgnoreCase(raw_name, "midi launcher")) {
            out.kind = .midi_launcher;
            return out;
        }
        if (containsIgnoreCase(raw_name, "multi lights") or containsIgnoreCase(raw_name, "multilights")) {
            out.kind = .midi_ext_multi_lights;
            return out;
        }
        if (containsIgnoreCase(raw_name, "genericmidi") or containsIgnoreCase(raw_name, "midiext") or containsIgnoreCase(raw_name, "midi extension")) {
            out.kind = .midi_ext;
            return out;
        }
        if (containsIgnoreCase(raw_name, "resonator")) {
            if (mx.params.len >= 34) {
                if (blobContains(mx.blob, "\"TimeMode1ms4\"")) {
                    out.kind = .resonator4;
                } else if (blobContains(mx.blob, "\"Up\"") or blobContains(mx.blob, "\"Down\"")) {
                    out.kind = .resonator301;
                } else {
                    out.kind = .resonator3;
                }
            } else if (mx.params.len >= 18) {
                out.kind = .resonator2;
            } else {
                out.kind = .resonator1;
            }
            return out;
        }
        if (containsIgnoreCase(raw_name, "lightspeed")) {
            out.kind = .lightspeed;
            return out;
        }
        if (containsIgnoreCase(raw_name, "cycle lights") or containsIgnoreCase(raw_name, "cyclelights")) {
            out.kind = .cycle_lights;
            return out;
        }
        if (containsIgnoreCase(raw_name, "cycle samples") or containsIgnoreCase(raw_name, "cyclesamples")) {
            out.kind = .cycle_samples;
            return out;
        }
        if (containsIgnoreCase(raw_name, "supersonic")) {
            out.kind = .supersonic;
            return out;
        }
        if (containsIgnoreCase(raw_name, "wormhole lite")) {
            out.kind = .wormhole_lite;
            return out;
        }
        if (containsIgnoreCase(raw_name, "wormhole")) {
            out.kind = .wormhole;
            return out;
        }
        if (containsIgnoreCase(raw_name, "blackhole")) {
            out.kind = .blackhole;
            return out;
        }
        if (containsIgnoreCase(raw_name, "auto page") or containsIgnoreCase(raw_name, "autopage")) {
            out.kind = .auto_page;
            return out;
        }
        if (containsIgnoreCase(raw_name, "page switcher") or containsIgnoreCase(raw_name, "pageswitcher")) {
            out.kind = .page_switcher;
            return out;
        }
        if (containsIgnoreCase(raw_name, "grid filter") or containsIgnoreCase(raw_name, "gridfilter")) {
            out.kind = .grid_filter;
            return out;
        }
        if (containsIgnoreCase(raw_name, "midi transform") or containsIgnoreCase(raw_name, "miditransform")) {
            out.kind = .midi_transform;
            return out;
        }
        if (containsIgnoreCase(raw_name, "set notes") or containsIgnoreCase(raw_name, "setnotes")) {
            out.kind = .set_notes;
            return out;
        }
        if (containsIgnoreCase(raw_name, "multi reset") or containsIgnoreCase(raw_name, "multireset")) {
            out.kind = .multi_reset;
            return out;
        }
        if (containsIgnoreCase(raw_name, "twist")) {
            out.kind = .twist;
            return out;
        }
        if (containsIgnoreCase(raw_name, "flip")) {
            out.kind = .flip;
            return out;
        }
        if (containsIgnoreCase(raw_name, "iris")) {
            out.kind = .iris;
            return out;
        }
        if (containsIgnoreCase(raw_name, "infinity")) {
            out.kind = .infinity;
            return out;
        }
        if (containsIgnoreCase(raw_name, "delay")) {
            out.kind = .delay;
            return out;
        }
        if (containsIgnoreCase(raw_name, "multi")) {
            out.kind = if (blobContains(mx.blob, "\"live.numbox\"")) .multi_outbreak else .multi_kaskobi;
            return out;
        }
    }

    // Legacy fallback: any MxDevice with LomId or dropped .mid behaves as MIDIext
    if (mx.lom_id > 0 or mx.mid_name.len > 0 or mx.mid_rel.len > 0 or mx.drops.len > 0) {
        out.kind = .midi_ext;
    }
    return out;
}

// ============================================================================
// Max Parameter & JSON Blob Helpers
// ============================================================================

pub fn paramByIndex(params: []const MxParam, idx: u16) ?MxParam {
    for (params) |p| if (p.index == idx) return p;
    return null;
}

pub fn paramByName(params: []const MxParam, name: []const u8) ?MxParam {
    for (params) |p| if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
    return null;
}

pub fn paramFloat(params: []const MxParam, idx: u16, fallback: f64) f64 {
    return if (paramByIndex(params, idx)) |p| p.value else fallback;
}

pub fn paramInt(params: []const MxParam, idx: u16, fallback: i32) i32 {
    if (paramByIndex(params, idx)) |p| {
        if (std.math.isFinite(p.value)) return @intFromFloat(@round(p.value));
    }
    return fallback;
}

pub fn blobContains(blob: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, blob, needle) != null;
}

/// Finds `"key" : [ ... ]` in a Max JSON blob and returns the slice inside `[...]`.
fn findBlobArrayBody(blob: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < blob.len) {
        const q = std.mem.indexOfScalarPos(u8, blob, pos, '"') orelse return null;
        if (q + 1 + key.len >= blob.len) return null;
        if (std.mem.eql(u8, blob[q + 1 .. q + 1 + key.len], key) and blob[q + 1 + key.len] == '"') {
            var p = q + 2 + key.len;
            while (p < blob.len and isWs(blob[p])) : (p += 1) {}
            if (p < blob.len and blob[p] == ':') {
                p += 1;
                while (p < blob.len and isWs(blob[p])) : (p += 1) {}
                if (p < blob.len and blob[p] == '[') {
                    const start = p + 1;
                    const end = std.mem.indexOfScalarPos(u8, blob, start, ']') orelse return null;
                    return blob[start..end];
                }
            }
        }
        pos = q + 1;
    }
    return null;
}

pub fn blobGetF64List(blob: []const u8, key: []const u8, out: []f64) usize {
    const body = findBlobArrayBody(blob, key) orelse return 0;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, " ,\t\r\n");
    while (it.next()) |tok| {
        if (n >= out.len) break;
        const v = std.fmt.parseFloat(f64, tok) catch continue;
        if (std.math.isFinite(v)) {
            out[n] = v;
            n += 1;
        }
    }
    return n;
}

pub fn blobGetI32List(blob: []const u8, key: []const u8, out: []i32) usize {
    const body = findBlobArrayBody(blob, key) orelse return 0;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, body, " ,\t\r\n");
    while (it.next()) |tok| {
        if (n >= out.len) break;
        const v = std.fmt.parseFloat(f64, tok) catch continue;
        if (std.math.isFinite(v)) {
            out[n] = @intFromFloat(@round(v));
            n += 1;
        }
    }
    return n;
}

pub fn blobFirstF64(blob: []const u8, key: []const u8) ?f64 {
    var buf: [1]f64 = undefined;
    return if (blobGetF64List(blob, key, &buf) > 0) buf[0] else null;
}

pub fn blobFirstI32(blob: []const u8, key: []const u8) ?i32 {
    var buf: [1]i32 = undefined;
    return if (blobGetI32List(blob, key, &buf) > 0) buf[0] else null;
}

pub fn blobHasOne(blob: []const u8, key: []const u8) bool {
    var buf: [8]i32 = undefined;
    const n = blobGetI32List(blob, key, &buf);
    for (buf[0..n]) |v| if (v == 1) return true;
    return false;
}

// ============================================================================
// Rhythm / Timing Conversion (Amethyst RateConversion.kt)
// ============================================================================

/// Returns duration in milliseconds for a whole-note fraction (`num / den` of a 4-beat bar).
pub fn fractionToMs(num: f64, den: f64, bpm: f64) f64 {
    if (den <= 0.0 or bpm <= 0.0) return 0.0;
    return (240000.0 / bpm) * (num / den);
}

fn delayRateMs(idx: i32, bpm: f64) f64 {
    return switch (idx) {
        0 => fractionToMs(1, 128, bpm),
        1 => fractionToMs(1, 64, bpm),
        2 => fractionToMs(1, 32, bpm),
        3 => fractionToMs(1, 16, bpm),
        4 => fractionToMs(1, 8, bpm),
        5 => fractionToMs(1, 4, bpm),
        6 => fractionToMs(1, 2, bpm),
        7 => fractionToMs(1, 1, bpm),
        else => fractionToMs(1, 8, bpm),
    };
}

fn irisRateMs(idx: i32, bpm: f64) f64 {
    return switch (idx) {
        0 => fractionToMs(1, 128, bpm),
        1 => fractionToMs(1, 64, bpm),
        2 => fractionToMs(1, 48, bpm),
        3 => fractionToMs(1, 32, bpm),
        4 => fractionToMs(1, 24, bpm),
        5 => fractionToMs(1, 16, bpm),
        6 => fractionToMs(1, 12, bpm),
        7 => fractionToMs(1, 8, bpm),
        8 => fractionToMs(1, 4, bpm),
        else => fractionToMs(1, 8, bpm),
    };
}

fn launcherProSyncMs(idx: i32, bpm: f64) f64 {
    return switch (idx) {
        0 => fractionToMs(1, 128, bpm),
        1 => fractionToMs(1, 64, bpm),
        2 => fractionToMs(1, 48, bpm),
        3 => fractionToMs(1, 32, bpm),
        4 => fractionToMs(1, 24, bpm),
        5 => fractionToMs(1, 16, bpm),
        6 => fractionToMs(1, 12, bpm),
        7 => fractionToMs(1, 8, bpm),
        8 => fractionToMs(1, 4, bpm),
        9 => fractionToMs(1, 2, bpm),
        10 => fractionToMs(1, 1, bpm),
        else => fractionToMs(1, 64, bpm),
    };
}

/// Amethyst Resonator 2 / 3 log-scaled Max dial float conversion.
fn convertResonatorFloat(raw: f64) f64 {
    if (@abs(raw - 10.0) <= 1e-6 or @abs(raw - 2000.0) <= 1e-6) return raw;
    const ln2 = @log(2.0);
    const b = 200.0 / ln2;
    const a_c = 719.005432 - b * @log(100.0);
    const v = @exp((raw - a_c) / b);
    return if (std.math.isFinite(v)) std.math.clamp(v, 1.0, 60000.0) else 100.0;
}

// ============================================================================
// Lightshow Effect Simulators
// ============================================================================

/// Outbreak Delay (`DelayAdapter`): shifts note start by synced/ms delay and optionally scales duration by gate%.
pub fn applyDelay(a: std.mem.Allocator, mx: MxDeviceData, bpm: f64, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    const free_mode = (blobFirstI32(mx.blob, "live.text") orelse 0) == 1;
    const delay_ms: f64 = if (free_mode)
        std.math.clamp(blobFirstF64(mx.blob, "Rate[2]") orelse 100.0, 0.0, 60000.0)
    else
        delayRateMs(blobFirstI32(mx.blob, "Rate") orelse 4, bpm);
    const gate_raw = blobFirstF64(mx.blob, "Rate[1]") orelse 100.0;
    const gate_frac = if (gate_raw > 0.0) std.math.clamp(gate_raw / 100.0, 0.05, 4.0) else 1.0;

    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        var copy = sn;
        copy.start_ms += delay_ms;
        if (gate_raw > 0.0 and gate_raw != 100.0) {
            copy.dur_ms = @max(copy.dur_ms * gate_frac, 5.0);
        }
        try out.append(a, copy);
    }
}

/// Outbreak Flip (`FlipAdapter`): mirror H/V or rotate 90/180/270 degrees, optionally keeping original.
pub fn applyFlip(a: std.mem.Allocator, mx: MxDeviceData, layout: NoteLayout, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    const mode = blobFirstI32(mx.blob, "number") orelse 1;
    const mirror_dir = blobFirstI32(mx.blob, "umenu") orelse 0;
    const rot_dir = blobFirstI32(mx.blob, "umenu[1]") orelse 0;
    const keep_orig = (blobFirstI32(mx.blob, "pictctrl") orelse 0) == 1;

    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        if (keep_orig) try out.append(a, sn);

        const xy = midiNoteToXY(layout, sn.note) orelse {
            if (!keep_orig) try out.append(a, sn);
            continue;
        };
        const r = xy[0];
        const c = xy[1];
        var nr: u8 = r;
        var nc: u8 = c;
        if (mode == 1) {
            switch (mirror_dir) {
                0 => nc = 7 - c, // Horizontal
                1 => nr = 7 - r, // Vertical
                2 => {
                    nr = 7 - r;
                    nc = 7 - c;
                },
                else => nc = 7 - c,
            }
        } else if (mode == 2) {
            switch (rot_dir) {
                0 => { // 90 CW
                    nr = c;
                    nc = 7 - r;
                },
                1 => { // 180
                    nr = 7 - r;
                    nc = 7 - c;
                },
                2 => { // 270 CW
                    nr = 7 - c;
                    nc = r;
                },
                else => {},
            }
        }
        var copy = sn;
        copy.note = xyToMidiNote(layout, nr, nc);
        try out.append(a, copy);
    }
}

/// Kaskobi MidiTransform (`MidiTransformAdapter`): param 0 enum: 0=Rot270, 1=Rot90, 2=Rot180, 3=FlipH, 4=FlipV.
pub fn applyMidiTransform(a: std.mem.Allocator, mx: MxDeviceData, layout: NoteLayout, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    const mode = paramInt(mx.params, 0, 0);
    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        const xy = midiNoteToXY(layout, sn.note) orelse {
            try out.append(a, sn);
            continue;
        };
        const r = xy[0];
        const c = xy[1];
        var nr = r;
        var nc = c;
        switch (mode) {
            0 => { // 270 CW
                nr = 7 - c;
                nc = r;
            },
            1 => { // 90 CW
                nr = c;
                nc = 7 - r;
            },
            2 => { // 180
                nr = 7 - r;
                nc = 7 - c;
            },
            3 => nc = 7 - c, // Flip H
            4 => nr = 7 - r, // Flip V
            else => {},
        }
        var copy = sn;
        copy.note = xyToMidiNote(layout, nr, nc);
        try out.append(a, copy);
    }
}

/// Kaskobi GridFilter (`GridFilterAdapter`): `matrixctrl` triplets `[x, y, enabled]` (0..7) filter grid pads.
pub fn applyGridFilter(a: std.mem.Allocator, mx: MxDeviceData, layout: NoteLayout, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    var vals: [256]i32 = undefined;
    const n = blobGetI32List(mx.blob, "matrixctrl", &vals);
    if (n < 3) {
        const rem = max_sim_notes -| out.items.len;
        try out.appendSlice(a, in_notes[0..@min(in_notes.len, rem)]);
        return;
    }

    var allowed: [64]bool = @splat(false);
    var i: usize = 0;
    while (i + 2 < n) : (i += 3) {
        const x = vals[i];
        const y = vals[i + 1];
        const en = vals[i + 2];
        if (en != 0 and x >= 0 and x < 8 and y >= 0 and y < 8) {
            allowed[@as(usize, @intCast(y)) * 8 + @as(usize, @intCast(x))] = true;
        }
    }

    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        const xy = midiNoteToXY(layout, sn.note) orelse continue;
        if (allowed[@as(usize, xy[0]) * 8 + xy[1]]) {
            try out.append(a, sn);
        }
    }
}

/// Kaskobi SetNotes (`SetNotesAdapter`): overrides note pitch and/or velocity based on blob enable flags + params 0/1.
pub fn applySetNotes(a: std.mem.Allocator, mx: MxDeviceData, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    const set_pitch = (blobFirstI32(mx.blob, "Set Pitch") orelse 0) == 1;
    const set_vel = (blobFirstI32(mx.blob, "Set Velocity") orelse 0) == 1;
    const pitch: u8 = @intCast(std.math.clamp(paramInt(mx.params, 0, 0), 0, 127));
    const vel: u8 = @intCast(std.math.clamp(paramInt(mx.params, 1, 127), 0, 127));

    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        var copy = sn;
        if (set_pitch) copy.note = pitch;
        if (set_vel) copy.vel = vel;
        try out.append(a, copy);
    }
}

/// Outbreak Infinity (`InfinityAdapter`): converts note to sustained/infinite hold.
pub fn applyInfinity(a: std.mem.Allocator, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    for (in_notes) |sn| {
        if (out.items.len >= max_sim_notes) break;
        var copy = sn;
        copy.dur_ms = @max(copy.dur_ms, 30000.0);
        copy.infinite = true;
        try out.append(a, copy);
    }
}

/// Outbreak Iris (`IrisAdapter`): steps each incoming note through a timed sequence of palette velocities.
pub fn applyIris(a: std.mem.Allocator, mx: MxDeviceData, bpm: f64, in_notes: []const SimNote, out: *std.ArrayList(SimNote)) !void {
    var raw_vels: [128]i32 = undefined;
    const n_raw = blobGetI32List(mx.blob, "table", &raw_vels);
    var vels: [128]u8 = undefined;
    var n_vels: usize = 0;
    for (raw_vels[0..n_raw]) |v| {
        if (v > 0 and v <= 127) {
            vels[n_vels] = @intCast(v);
            n_vels += 1;
        }
    }
    if (n_vels == 0) {
        const rem = max_sim_notes -| out.items.len;
        try out.appendSlice(a, in_notes[0..@min(in_notes.len, rem)]);
        return;
    }

    const by_ms = (blobFirstI32(mx.blob, "live.text[1]") orelse 0) == 1;
    const step_ms: f64 = if (by_ms)
        std.math.clamp(blobFirstF64(mx.blob, "Rate[2]") orelse 100.0, 5.0, 60000.0)
    else
        @max(irisRateMs(blobFirstI32(mx.blob, "Rate") orelse 7, bpm), 5.0);
    const loop_mode = (blobFirstI32(mx.blob, "live.text") orelse 0) == 1;

    for (in_notes) |sn| {
        for (vels[0..n_vels], 0..) |v, idx| {
            if (out.items.len >= max_sim_notes) break;
            var copy = sn;
            copy.start_ms = sn.start_ms + @as(f64, @floatFromInt(idx)) * step_ms;
            copy.dur_ms = step_ms;
            copy.vel = v;
            copy.loop = loop_mode;
            try out.append(a, copy);
        }
    }
}

/// Outbreak DepthsSelector (`DepthsSelectorAdapter`): stamps layer priority (`live.numbox[1]`) and optional mask channel (`live.numbox`).
pub const DepthsSelectorInfo = struct {
    layer: i16 = 0,
    mask_channel: u8 = 0,
};

pub fn parseDepthsSelector(mx: MxDeviceData) DepthsSelectorInfo {
    const layer = blobFirstI32(mx.blob, "live.numbox[1]") orelse 0;
    const ch = blobFirstI32(mx.blob, "live.numbox") orelse 0;
    return .{
        .layer = @intCast(std.math.clamp(layer, -128, 128)),
        .mask_channel = @intCast(std.math.clamp(ch, 0, 127)),
    };
}

/// Outbreak DepthsMixer (`DepthsMixerAdapter`): returns channel from `live.numbox`.
pub fn parseDepthsMixerChannel(mx: MxDeviceData) ?u8 {
    const ch = blobFirstI32(mx.blob, "live.numbox") orelse return null;
    if (ch <= 0 or ch > 127) return null;
    return @intCast(ch);
}

// ============================================================================
// Kaskobi Resonator 1 / 2 / 3 / 3.0.1 / 4 Wave Generator
// ============================================================================

pub fn applyResonator(
    a: std.mem.Allocator,
    kind: MxDeviceKind,
    mx: MxDeviceData,
    layout: NoteLayout,
    bpm: f64,
    in_notes: []const SimNote,
    out: *std.ArrayList(SimNote),
) !void {
    var dir_up = false;
    var dir_down = false;
    var dir_left = false;
    var dir_right = false;
    var dir_ul = false;
    var dir_ur = false;
    var dir_dl = false;
    var dir_dr = false;
    var shape_circle = false;
    var shape_diamond = false;
    var shape_square = false;
    var single_led = false;

    var steps: usize = 8;
    var step_delay_ms: f64 = 50.0;
    var note_len_ms: f64 = 100.0;
    var grad_enabled = false;
    var grad_colors: [16]u8 = @splat(0);
    var grad_count: usize = 0;
    var grad_step_ms: f64 = 80.0;

    switch (kind) {
        .resonator1 => {
            dir_ul = blobHasOne(mx.blob, "pictctrl[3]");
            dir_dr = blobHasOne(mx.blob, "pictctrl[4]");
            dir_ur = blobHasOne(mx.blob, "pictctrl[5]");
            dir_dl = blobHasOne(mx.blob, "pictctrl[6]");
            dir_left = blobHasOne(mx.blob, "pictctrl[8]");
            dir_right = blobHasOne(mx.blob, "pictctrl[9]");
            dir_down = blobHasOne(mx.blob, "pictctrl[10]");
            dir_up = blobHasOne(mx.blob, "pictctrl[11]");
            shape_square = blobHasOne(mx.blob, "pictctrl[12]");
            shape_circle = blobHasOne(mx.blob, "pictctrl[15]");
            steps = 8;
            step_delay_ms = @max(blobFirstF64(mx.blob, "live.dial[1]") orelse 50.0, 5.0);
            note_len_ms = @max(blobFirstF64(mx.blob, "live.dial") orelse 100.0, 10.0);
        },
        .resonator2 => {
            dir_ul = blobHasOne(mx.blob, "pictctrl[3]");
            dir_dr = blobHasOne(mx.blob, "pictctrl[4]");
            dir_ur = blobHasOne(mx.blob, "pictctrl[5]");
            dir_dl = blobHasOne(mx.blob, "pictctrl[6]");
            dir_left = blobHasOne(mx.blob, "pictctrl[8]");
            dir_right = blobHasOne(mx.blob, "pictctrl[9]");
            dir_down = blobHasOne(mx.blob, "pictctrl[10]");
            dir_up = blobHasOne(mx.blob, "pictctrl[11]");
            steps = @intCast(std.math.clamp(paramInt(mx.params, 1, 8), 1, 16));
            step_delay_ms = @max(convertResonatorFloat(paramFloat(mx.params, 19, 100.0)), 5.0);
            note_len_ms = @max(convertResonatorFloat(paramFloat(mx.params, 20, 100.0)), 10.0);
            grad_step_ms = @max(convertResonatorFloat(paramFloat(mx.params, 21, 100.0)), 10.0);
            grad_enabled = paramInt(mx.params, 18, 0) == 1;
            const cnt: usize = @intCast(std.math.clamp(paramInt(mx.params, 13, 1), 1, 12));
            const ids = [_]u16{ 14, 3, 4, 5, 2, 8, 7, 6, 12, 11, 10, 9 };
            grad_count = cnt;
            for (0..cnt) |k| {
                grad_colors[k] = @intCast(std.math.clamp(paramInt(mx.params, ids[k], 0), 0, 127));
            }
        },
        .resonator3, .resonator301 => {
            const is301 = kind == .resonator301;
            if (is301) {
                dir_up = blobHasOne(mx.blob, "Up");
                dir_down = blobHasOne(mx.blob, "Down");
                dir_left = blobHasOne(mx.blob, "Left");
                dir_right = blobHasOne(mx.blob, "Right");
                dir_ul = blobHasOne(mx.blob, "UpLeft");
                dir_ur = blobHasOne(mx.blob, "UpRight");
                dir_dl = blobHasOne(mx.blob, "DownLeft");
                dir_dr = blobHasOne(mx.blob, "DownRight");
                shape_circle = blobHasOne(mx.blob, "Circle");
                shape_diamond = blobHasOne(mx.blob, "Diamond");
                shape_square = blobHasOne(mx.blob, "Square");
                single_led = blobHasOne(mx.blob, "SingleLED");
            } else {
                dir_ul = blobHasOne(mx.blob, "pictctrl[3]");
                dir_dr = blobHasOne(mx.blob, "pictctrl[4]");
                dir_ur = blobHasOne(mx.blob, "pictctrl[5]");
                dir_dl = blobHasOne(mx.blob, "pictctrl[6]");
                dir_left = blobHasOne(mx.blob, "pictctrl[8]");
                dir_right = blobHasOne(mx.blob, "pictctrl[9]");
                dir_down = blobHasOne(mx.blob, "pictctrl[10]");
                dir_up = blobHasOne(mx.blob, "pictctrl[11]");
                shape_square = blobHasOne(mx.blob, "pictctrl[12]");
                shape_circle = blobHasOne(mx.blob, "pictctrl[13]");
                shape_diamond = blobHasOne(mx.blob, "pictctrl[15]");
                single_led = blobHasOne(mx.blob, "SingleLED");
            }
            const nl_is_ms = paramInt(mx.params, if (is301) 9 else 26, 1) == 1;
            const nl_ms = convertResonatorFloat(paramFloat(mx.params, if (is301) 10 else 21, 100.0));
            const nl_sync = paramInt(mx.params, if (is301) 11 else 20, 4);
            note_len_ms = if (nl_is_ms) nl_ms else delayRateMs(nl_sync, bpm);

            const sd_is_ms = paramInt(mx.params, if (is301) 34 else 28, 1) == 1;
            const sd_ms = convertResonatorFloat(paramFloat(mx.params, if (is301) 14 else 19, 50.0));
            const sd_sync = paramInt(mx.params, if (is301) 15 else 18, 4);
            step_delay_ms = @max(if (sd_is_ms) sd_ms else delayRateMs(sd_sync, bpm), 5.0);

            const gc_is_ms = paramInt(mx.params, if (is301) 35 else 30, 1) == 1;
            const gc_ms = convertResonatorFloat(paramFloat(mx.params, if (is301) 12 else 23, 80.0));
            const gc_sync = paramInt(mx.params, if (is301) 13 else 22, 4);
            grad_step_ms = @max(if (gc_is_ms) gc_ms else delayRateMs(gc_sync, bpm), 10.0);

            const raw_steps = paramInt(mx.params, if (is301) 8 else 0, 8) - 1;
            steps = @intCast(std.math.clamp(raw_steps, 1, 16));
            grad_enabled = paramInt(mx.params, if (is301) 1 else 24, 0) == 1;
            const raw_cnt = paramInt(mx.params, if (is301) 2 else 17, 2) - 1;
            grad_count = @intCast(std.math.clamp(raw_cnt, 1, 16));
            const ids301 = [_]u16{ 29, 22, 28, 27, 26, 21, 25, 24, 23, 20, 19, 18, 33, 32, 31, 30 };
            const ids300 = [_]u16{ 12, 5, 11, 10, 9, 4, 8, 7, 6, 3, 2, 1, 16, 15, 14, 13 };
            const ids = if (is301) ids301 else ids300;
            for (0..grad_count) |k| {
                grad_colors[k] = @intCast(std.math.clamp(paramInt(mx.params, ids[k], 0), 0, 127));
            }
        },
        .resonator4 => {
            dir_up = blobHasOne(mx.blob, "Up");
            dir_down = blobHasOne(mx.blob, "Down");
            dir_left = blobHasOne(mx.blob, "Left");
            dir_right = blobHasOne(mx.blob, "Right");
            dir_ul = blobHasOne(mx.blob, "UpLeft");
            dir_ur = blobHasOne(mx.blob, "UpRight");
            dir_dl = blobHasOne(mx.blob, "DownLeft");
            dir_dr = blobHasOne(mx.blob, "DownRight");
            shape_circle = blobHasOne(mx.blob, "Circle");
            shape_diamond = blobHasOne(mx.blob, "Diamond");
            shape_square = blobHasOne(mx.blob, "Square");
            single_led = blobHasOne(mx.blob, "SingleLED");

            const nl_is_ms = paramInt(mx.params, 11, 0) == 0;
            const nl_ms = blobFirstF64(mx.blob, "TimeMode1ms4") orelse 100.0;
            const nl_sync = blobFirstI32(mx.blob, "TimeMode1sync") orelse 1;
            note_len_ms = @max(if (nl_is_ms) nl_ms else delayRateMs(nl_sync, bpm), 10.0);

            const sd_is_ms = paramInt(mx.params, 35, 0) == 0;
            const sd_ms = paramFloat(mx.params, 12, 50.0);
            const sd_sync = paramInt(mx.params, 13, 4);
            step_delay_ms = @max(if (sd_is_ms) sd_ms else delayRateMs(sd_sync, bpm), 5.0);

            const gc_is_ms = paramInt(mx.params, 34, 0) == 0;
            const gc_ms = paramFloat(mx.params, 14, 80.0);
            const gc_sync = paramInt(mx.params, 15, 4);
            grad_step_ms = @max(if (gc_is_ms) gc_ms else delayRateMs(gc_sync, bpm), 10.0);

            steps = @intCast(std.math.clamp(paramInt(mx.params, 10, 8) - 1, 1, 16));
            grad_enabled = paramInt(mx.params, 1, 0) == 1;
            grad_count = @intCast(std.math.clamp(paramInt(mx.params, 2, 2) - 1, 1, 16));
            const ids = [_]u16{ 29, 22, 28, 27, 26, 21, 25, 24, 23, 20, 19, 18, 33, 32, 31, 30 };
            for (0..grad_count) |k| {
                grad_colors[k] = @intCast(std.math.clamp(paramInt(mx.params, ids[k], 0), 0, 127));
            }
        },
        else => return,
    }

    const dirs = [_]struct { en: bool, dr: i8, dc: i8 }{
        .{ .en = dir_ul, .dr = -1, .dc = -1 },
        .{ .en = dir_up, .dr = -1, .dc = 0 },
        .{ .en = dir_ur, .dr = -1, .dc = 1 },
        .{ .en = dir_left, .dr = 0, .dc = -1 },
        .{ .en = dir_right, .dr = 0, .dc = 1 },
        .{ .en = dir_dl, .dr = 1, .dc = -1 },
        .{ .en = dir_down, .dr = 1, .dc = 0 },
        .{ .en = dir_dr, .dr = 1, .dc = 1 },
    };

    var any_dir = false;
    for (dirs) |d| if (d.en) {
        any_dir = true;
    };

    const emitCell = struct {
        fn emit(
            alloc: std.mem.Allocator,
            dst: *std.ArrayList(SimNote),
            base: SimNote,
            lay: NoteLayout,
            rr: i32,
            cc: i32,
            t_off: f64,
            dur: f64,
            g_en: bool,
            g_cols: []const u8,
            g_step: f64,
        ) !void {
            if (rr < 0 or rr > 7 or cc < 0 or cc > 7) return;
            const n = xyToMidiNote(lay, @intCast(rr), @intCast(cc));
            if (g_en and g_cols.len > 1) {
                for (g_cols, 0..) |gv, k| {
                    if (dst.items.len >= max_sim_notes) return;
                    if (gv == 0) continue;
                    var copy = base;
                    copy.note = n;
                    copy.start_ms = base.start_ms + t_off + @as(f64, @floatFromInt(k)) * g_step;
                    copy.dur_ms = g_step;
                    copy.vel = gv;
                    try dst.append(alloc, copy);
                }
            } else {
                if (dst.items.len >= max_sim_notes) return;
                var copy = base;
                copy.note = n;
                copy.start_ms = base.start_ms + t_off;
                copy.dur_ms = dur;
                if (g_en and g_cols.len == 1 and g_cols[0] > 0) copy.vel = g_cols[0];
                try dst.append(alloc, copy);
            }
        }
    }.emit;

    const g_slice = grad_colors[0..grad_count];
    for (in_notes) |sn| {
        const xy = midiNoteToXY(layout, sn.note) orelse continue;
        const r0: i32 = xy[0];
        const c0: i32 = xy[1];

        // Origin pad (step 0) when singleLED or any wave is active
        if (single_led or any_dir or shape_circle or shape_diamond or shape_square) {
            try emitCell(a, out, sn, layout, r0, c0, 0.0, note_len_ms, grad_enabled, g_slice, grad_step_ms);
        }

        // 8-direction linear beams
        for (dirs) |d| {
            if (!d.en) continue;
            for (1..steps + 1) |s| {
                const rr = r0 + @as(i32, d.dr) * @as(i32, @intCast(s));
                const cc = c0 + @as(i32, d.dc) * @as(i32, @intCast(s));
                if (rr < 0 or rr > 7 or cc < 0 or cc > 7) break;
                try emitCell(a, out, sn, layout, rr, cc, @as(f64, @floatFromInt(s)) * step_delay_ms, note_len_ms, grad_enabled, g_slice, grad_step_ms);
            }
        }

        // Radial shapes (Square = Chebyshev ring, Diamond = Manhattan ring, Circle = Euclidean ring)
        if (shape_square or shape_diamond or shape_circle) {
            const max_r: i32 = @intCast(@min(steps, 8));
            var rad: i32 = 1;
            while (rad <= max_r) : (rad += 1) {
                const t_off = @as(f64, @floatFromInt(rad)) * step_delay_ms;
                var rr: i32 = 0;
                while (rr < 8) : (rr += 1) {
                    var cc: i32 = 0;
                    while (cc < 8) : (cc += 1) {
                        const dr = @abs(rr - r0);
                        const dc = @abs(cc - c0);
                        const hit = (shape_square and @max(dr, dc) == @as(u32, @intCast(rad))) or
                            (shape_diamond and (dr + dc) == @as(u32, @intCast(rad))) or
                            (shape_circle and blk: {
                                const d2 = dr * dr + dc * dc;
                                const r_lo = (rad - 1) * (rad - 1);
                                const r_hi = rad * rad;
                                break :blk d2 > @as(u32, @intCast(r_lo)) and d2 <= @as(u32, @intCast(r_hi));
                            });
                        if (hit) {
                            try emitCell(a, out, sn, layout, rr, cc, t_off, note_len_ms, grad_enabled, g_slice, grad_step_ms);
                        }
                    }
                }
            }
        }
    }
}

// ============================================================================
// MIDIext / MidiLauncher / MidiLauncherPro / Lightspeed / CycleLights / MultiLights
// ============================================================================

pub const MidiExtSettings = struct {
    is_mask: bool = false,
    loop: bool = false,
};

pub fn parseGenericMidiExtSettings(mx: MxDeviceData) MidiExtSettings {
    var s: MidiExtSettings = .{};
    const name = if (mx.patch_name.len > 0) mx.patch_name else basenameOf(mx.patch_rel);
    // Only MIDIext 5.0 uses param[0] (Mode: Launch/Mask) and param[1] (Loop toggle 0..1).
    // Older Midi Extension.amxd stores tempo numboxes (e.g. 120) at indices 0..3.
    const is_v5 = containsIgnoreCase(name, "midiext5");
    for (mx.params) |p| {
        if (is_v5) {
            if (p.index == 0 and @round(p.value) == 1.0) s.is_mask = true;
            if (p.index == 1 and p.value >= 0.5 and p.value <= 1.0) s.loop = true;
        } else {
            if (std.ascii.eqlIgnoreCase(p.name, "Loop") and p.value >= 0.5 and p.value <= 1.0) s.loop = true;
        }
    }
    return s;
}

pub const MidiLauncherSettings = struct {
    tempo_override: ?f64 = null,
    skip_silence: bool = false,
    mirror_mode: u8 = 0, // 0=none, 1=H, 2=V, 3=both
    key_tracking: bool = false,
    root_note: u8 = 36,
    loop: bool = false,
    delay_ms: f64 = 0.0,
};

pub fn parseMidiLauncherSettings(kind: MxDeviceKind, id: IdentifiedMx, mx: MxDeviceData, bpm: f64) MidiLauncherSettings {
    var out: MidiLauncherSettings = .{};
    const is_latest_pro = id.has_hash and std.mem.eql(u8, &id.hash, "a114e5d1a7710271501649668c14f1ab");

    if (kind == .midi_launcher) {
        const tempo_p = paramByName(mx.params, "MIDIext1Tempo") orelse paramByIndex(mx.params, 12);
        if (tempo_p) |tp| {
            if (tp.value >= 20.0 and tp.value <= 400.0) out.tempo_override = tp.value;
        }
        const skip_p = paramByName(mx.params, "Skip Silence") orelse paramByIndex(mx.params, 16) orelse paramByIndex(mx.params, 15);
        if (skip_p) |sp| out.skip_silence = @round(sp.value) == 1.0;
        return out;
    }

    // MidiLauncher Pro
    const skip_idx: u16 = if (is_latest_pro) 17 else blk: {
        for (mx.params) |p| if (p.index == 16 and p.kind == .int) break :blk 16;
        break :blk 15;
    };
    const skip_p = paramByName(mx.params, "Skip Silence") orelse paramByIndex(mx.params, skip_idx);
    if (skip_p) |sp| out.skip_silence = @round(sp.value) == 1.0;

    if (!is_latest_pro and id.has_hash) return out;

    if (paramByName(mx.params, "Mirror Mode") orelse paramByIndex(mx.params, 10)) |p| {
        out.mirror_mode = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(p.value))), 0, 3));
    }
    if (paramByName(mx.params, "Key Tracking") orelse paramByIndex(mx.params, 7)) |p| {
        out.key_tracking = @round(p.value) == 1.0;
    }
    if (paramByName(mx.params, "Loop") orelse paramByIndex(mx.params, 8)) |p| {
        out.loop = @round(p.value) == 1.0;
    }
    if (blobFirstI32(mx.blob, "Root Note")) |rn| {
        out.root_note = @intCast(std.math.clamp(rn, 0, 127));
    }
    if (paramByName(mx.params, "Delay") orelse paramByIndex(mx.params, 4)) |dp| {
        if (@round(dp.value) == 1.0) {
            const is_sync = if (paramByName(mx.params, "DelaySyncMS") orelse paramByIndex(mx.params, 5)) |sp| @round(sp.value) == 1.0 else false;
            if (is_sync) {
                const idx = if (paramByName(mx.params, "SyncDelay") orelse paramByIndex(mx.params, 18)) |p| @as(i32, @intFromFloat(@round(p.value))) else 1;
                out.delay_ms = launcherProSyncMs(idx, bpm);
            } else {
                const stored = if (paramByName(mx.params, "msDelay") orelse paramByIndex(mx.params, 30)) |p| p.value else 31320.877;
                const norm = (std.math.clamp(stored, 10.0, 60000.0) - 10.0) / 59990.0;
                out.delay_ms = 10.0 + 59990.0 * std.math.pow(f64, norm, 10.0);
            }
        }
    }
    return out;
}

/// Applies MidiLauncher Pro Mirror Mode + Key Tracking + Delay to a parsed sequence of MIDI notes.
pub fn transformLauncherNote(
    sn: SimNote,
    settings: MidiLauncherSettings,
    layout: NoteLayout,
    trigger_note: u8,
) ?SimNote {
    var copy = sn;
    copy.start_ms += settings.delay_ms;
    if (settings.loop) copy.loop = true;

    if (settings.mirror_mode != 0 or settings.key_tracking) {
        if (midiNoteToXY(layout, copy.note)) |xy| {
            var r: i32 = xy[0];
            var c: i32 = xy[1];
            if (settings.mirror_mode == 1 or settings.mirror_mode == 3) c = 7 - c;
            if (settings.mirror_mode == 2 or settings.mirror_mode == 3) r = 7 - r;

            if (settings.key_tracking) {
                if (midiNoteToXY(layout, settings.root_note)) |rxy| {
                    var rr: i32 = rxy[0];
                    var rc: i32 = rxy[1];
                    if (settings.mirror_mode == 1 or settings.mirror_mode == 3) rc = 7 - rc;
                    if (settings.mirror_mode == 2 or settings.mirror_mode == 3) rr = 7 - rr;
                    if (midiNoteToXY(layout, trigger_note)) |txy| {
                        r += @as(i32, txy[0]) - rr;
                        c += @as(i32, txy[1]) - rc;
                    }
                }
            }
            if (r < 0 or r > 7 or c < 0 or c > 7) return null;
            copy.note = xyToMidiNote(layout, @intCast(r), @intCast(c));
        }
    }
    return copy;
}

/// Exact Dovitate CycleLights slot order (Amethyst `CycleLightsAdapter.kt`).
const cycle_lights_slot_ids = [_]u16{
    185, 186, 187, 188, 189, 190, 191, 192,
    197, 199, 200, 201, 202, 198, 203, 204,
};

pub fn resolveCycleLightsDrop(mx: MxDeviceData, press_idx: usize, cycle_len: *usize) ?MxFileDrop {
    const raw_len = blobFirstI32(mx.blob, "live.numbox[8]") orelse @as(i32, @intCast(@min(mx.drops.len, 16)));
    const len: usize = @intCast(std.math.clamp(raw_len, 0, 16));
    if (len == 0) return null;
    cycle_len.* = @min(@as(usize, 24), lcmUsize(cycle_len.*, len));
    const slot_id = cycle_lights_slot_ids[press_idx % len];
    var name_buf: [24]u8 = undefined;
    const expected = std.fmt.bufPrint(&name_buf, "live.drop[{d}]", .{slot_id}) catch return null;
    for (mx.drops) |d| {
        if (std.mem.eql(u8, d.name, expected)) return d;
    }
    return null;
}

/// Exact Kaskobi MidiExtMultiLights slot order (Amethyst `MidiExtMultiLightsAdapter.kt`).
const multi_lights_slot_names = [_][]const u8{
    "live.drop",     "live.drop[7]",  "live.drop[9]",  "live.drop[10]",
    "live.drop[11]", "live.drop[8]",  "live.drop[12]", "live.drop[13]",
    "live.drop[14]", "live.drop[15]", "live.drop[16]", "live.drop[17]",
    "live.drop[18]", "live.drop[19]", "live.drop[20]", "live.drop[21]",
};

pub fn resolveMidiExtMultiDrop(mx: MxDeviceData, press_idx: usize, cycle_len: *usize) ?MxFileDrop {
    const raw_len = blobFirstI32(mx.blob, "num") orelse 1;
    const len: usize = @intCast(std.math.clamp(raw_len, 1, 16));
    cycle_len.* = @min(@as(usize, 24), lcmUsize(cycle_len.*, len));
    const expected = multi_lights_slot_names[press_idx % len];
    for (mx.drops) |d| {
        if (std.mem.eql(u8, d.name, expected)) return d;
    }
    return null;
}

/// Exact Dovitate Lightspeed drop-ID -> Launchpad Programmer XY index table (`LightspeedAdapter.kt`).
pub fn lightspeedIdToProgIndex(id: u16) ?u8 {
    return switch (id) {
        185 => 11, 186 => 12, 187 => 13, 188 => 14, 189 => 24, 190 => 23, 191 => 22, 192 => 21,
        193 => 81, 194 => 73, 195 => 72, 196 => 63, 197 => 44, 198 => 33, 199 => 43, 200 => 42,
        201 => 41, 202 => 34, 203 => 32, 204 => 31, 205 => 84, 206 => 83, 207 => 82, 208 => 74,
        209 => 71, 210 => 64, 211 => 62, 212 => 61, 213 => 54, 214 => 53, 215 => 52, 216 => 51,
        217 => 48, 218 => 47, 219 => 46, 220 => 45, 221 => 38, 222 => 37, 223 => 36, 224 => 35,
        225 => 28, 226 => 27, 227 => 26, 228 => 25, 229 => 18, 230 => 17, 231 => 16, 232 => 15,
        233 => 88, 234 => 87, 235 => 86, 236 => 85, 237 => 78, 238 => 77, 239 => 76, 240 => 75,
        241 => 68, 242 => 67, 243 => 66, 244 => 65, 245 => 58, 246 => 57, 247 => 56, 248 => 55,
        268 => 6,  269 => 5,  270 => 4,
        276 => 98, 277 => 97, 278 => 96, 279 => 95, 280 => 94, 281 => 93, 282 => 92, 283 => 91,
        287 => 80, 288 => 40, 289 => 20, 290 => 89, 291 => 70, 292 => 30, 293 => 60, 294 => 50,
        295 => 10, 296 => 79, 297 => 69, 298 => 59, 299 => 49, 300 => 39, 301 => 29, 302 => 19,
        303 => 8,  304 => 7,  305 => 3,  306 => 2,  307 => 1,
        else => null,
    };
}

pub fn resolveLightspeedDrop(mx: MxDeviceData, layout: NoteLayout, trig_note: u8) ?MxFileDrop {
    for (mx.drops) |d| {
        const id = firstUintInStr(d.name) orelse continue;
        const p_idx = lightspeedIdToProgIndex(id) orelse continue;
        const note = progIndexToMidiNote(layout, p_idx) orelse continue;
        if (note == trig_note) return d;
    }
    return null;
}

/// Exact Dovitate Supersonic drop-ID -> Launchpad Programmer XY index table (`SupersonicAdapter.kt`).
pub fn supersonicIdToProgIndex(id: u16) ?u8 {
    return switch (id) {
        1 => 48,   2 => 47,   3 => 46,   4 => 45,   5 => 38,   6 => 37,   7 => 36,   8 => 35,
        9 => 28,   10 => 27,  11 => 26,  12 => 25,  13 => 18,  14 => 17,  15 => 16,  16 => 15,
        17 => 88,  18 => 87,  19 => 86,  20 => 85,  21 => 78,  22 => 77,  23 => 76,  24 => 75,
        25 => 68,  26 => 67,  27 => 66,  28 => 65,  29 => 58,  30 => 57,  31 => 56,  32 => 55,
        33 => 10,  34 => 20,  35 => 30,  36 => 40,  37 => 50,  38 => 70,  39 => 19,  40 => 39,
        41 => 59,  42 => 52,  43 => 64,  44 => 73,  45 => 83,  46 => 33,  47 => 13,  48 => 60,
        49 => 80,  50 => 29,  51 => 49,  52 => 79,  53 => 89,  62 => 51,  64 => 63,  65 => 61,
        66 => 72,  67 => 82,  68 => 44,  69 => 32,  70 => 12,  71 => 69,  76 => 98,  77 => 7,
        78 => 4,   79 => 43,  80 => 31,  81 => 22,  82 => 11,  85 => 42,  86 => 24,  87 => 21,
        88 => 41,  89 => 53,  90 => 54,  91 => 62,  92 => 74,  93 => 71,  94 => 84,  95 => 81,
        96 => 34,  97 => 23,  98 => 14,  99 => 6,   100 => 97, 101 => 96, 102 => 95, 103 => 94,
        104 => 93, 105 => 92, 106 => 91, 107 => 8,  108 => 5,  109 => 3,  110 => 2,  111 => 1,
        else => null,
    };
}

pub const CycleSamplesSettings = struct {
    fade_in_ms: f32 = 0.0,
    fade_out_ms: f32 = 0.0,
    max_items: usize = 16,
};

pub fn parseCycleSamplesSettings(mx: MxDeviceData) CycleSamplesSettings {
    const fi = blobFirstF64(mx.blob, "live.dial") orelse paramFloat(mx.params, 2, 0.0);
    const fo = blobFirstF64(mx.blob, "live.dial[1]") orelse paramFloat(mx.params, 3, 0.0);
    const cl = blobFirstI32(mx.blob, "live.numbox[1]") orelse 16;
    return .{
        .fade_in_ms = @floatCast(std.math.clamp(fi, 0.0, 30000.0)),
        .fade_out_ms = @floatCast(std.math.clamp(fo, 0.0, 30000.0)),
        .max_items = @intCast(std.math.clamp(cl, 1, 16)),
    };
}

// ============================================================================
// Wormhole / Page Switchers & Multi-Press Cycling
// ============================================================================

/// Extracts a 0-based target chain index from Wormhole, WormholeLite, Blackhole, AutoPage, or Twist.
pub fn extractWormholeTarget(kind: MxDeviceKind, mx: MxDeviceData) ?u8 {
    if (!mx.on) return null;
    const raw: i32 = switch (kind) {
        .wormhole_lite, .auto_page => (blobFirstI32(mx.blob, "live.numbox") orelse return null) - 1,
        .blackhole => blobFirstI32(mx.blob, "number[15]") orelse return null,
        .wormhole => blk: {
            if ((blobFirstI32(mx.blob, "Enabler_1") orelse 0) != 1) return null;
            break :blk blobFirstI32(mx.blob, "Destination_1") orelse return null;
        },
        .twist => blk: {
            var enabled: [8]i32 = @splat(0);
            var targets: [8]i32 = @splat(0);
            const ne = blobGetI32List(mx.blob, "table[13]", &enabled);
            const nt = blobGetI32List(mx.blob, "table[1]", &targets);
            if (ne > 0 and nt > 0 and enabled[0] == 1) break :blk targets[0];
            return null;
        },
        else => return null,
    };
    if (raw < 0 or raw >= types.max_chains) return null;
    return @intCast(raw);
}

pub const MultiSettings = struct {
    steps: u8 = 1,
    note_mode: bool = true,
};

/// Parses Outbreak `Multi` (`MultiAdapter`) and Kaskobi `MultiEffect` (`MultiEffectAdapter`).
pub fn parseMultiSettings(kind: MxDeviceKind, mx: MxDeviceData) ?MultiSettings {
    if (kind == .multi_outbreak) {
        const steps_f = blobFirstF64(mx.blob, "live.numbox") orelse return null;
        const steps: u8 = if (!mx.on) 1 else @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(steps_f))), 1, 24));
        const mode_f = blobFirstF64(mx.blob, "live.text") orelse 0.0;
        const note_mode = !mx.on or @round(mode_f) != 1.0;
        return .{ .steps = steps, .note_mode = note_mode };
    }
    if (kind == .multi_kaskobi) {
        var steps_i: ?i32 = null;
        for (mx.params) |p| {
            if (p.kind == .int) {
                steps_i = @intFromFloat(@round(p.value));
                break;
            }
        }
        if (steps_i == null) steps_i = blobFirstI32(mx.blob, "num");
        const s = steps_i orelse 1;
        return .{
            .steps = if (!mx.on) 1 else @intCast(std.math.clamp(s, 1, 24)),
            .note_mode = false, // Kaskobi MultiEffect cycles branch ranges/selector sequentially
        };
    }
    return null;
}

// ============================================================================
// Internal Utilities
// ============================================================================

pub fn lcmUsize(a_v: usize, b_v: usize) usize {
    if (a_v == 0 or b_v == 0) return @max(a_v, b_v);
    var x = a_v;
    var y = b_v;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return (a_v / x) * b_v;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

pub fn firstUintInStr(s: []const u8) ?u16 {
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i >= s.len) return null;
    var j = i;
    while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
    return std.fmt.parseInt(u16, s[i..j], 10) catch null;
}

pub fn basenameOf(path: []const u8) []const u8 {
    var last: ?usize = null;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') last = i;
    }
    return if (last) |i| path[i + 1 ..] else path;
}

pub fn endsWithIgnoreCase(hay: []const u8, suffix: []const u8) bool {
    if (hay.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(hay[hay.len - suffix.len ..], suffix);
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn findProjectFile(files: []const VirtualFile, rel_path: []const u8, file_name: []const u8) ?VirtualFile {
    const base = if (file_name.len > 0) file_name else basenameOf(rel_path);
    if (rel_path.len > 0) {
        for (files) |f| {
            if (endsWithIgnoreCase(f.rel_path, rel_path)) return f;
        }
    }
    if (base.len > 0) {
        for (files) |f| {
            if (std.ascii.eqlIgnoreCase(basenameOf(f.rel_path), base)) return f;
        }
    }
    return null;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "m4l: blob parsing and wormhole extraction" {
    const wh = MxDeviceData{ .blob = "{\"Enabler_1\":[1.0],\"Destination_1\":[3.0]}" };
    try std.testing.expectEqual(@as(?u8, 3), extractWormholeTarget(.wormhole, wh));

    const wh_lite = MxDeviceData{ .blob = "{\"live.numbox\":[2.0]}" };
    try std.testing.expectEqual(@as(?u8, 1), extractWormholeTarget(.wormhole_lite, wh_lite));

    const bh = MxDeviceData{ .blob = "{\"number[15]\":[4.0]}" };
    try std.testing.expectEqual(@as(?u8, 4), extractWormholeTarget(.blackhole, bh));

    const ap = MxDeviceData{ .blob = "{\"live.numbox\":[5],\"live.numbox[43]\":[0]}" };
    try std.testing.expectEqual(@as(?u8, 4), extractWormholeTarget(.auto_page, ap));

    const tw = MxDeviceData{ .blob = "{\"table[13]\":[1,0,0,0,0,0,0,0],\"table[1]\":[2,0,0,0,0,0,0,0]}" };
    try std.testing.expectEqual(@as(?u8, 2), extractWormholeTarget(.twist, tw));
}

test "m4l: Flip, MidiTransform, GridFilter, SetNotes, Delay, Iris, Resonator" {
    const a = std.testing.allocator;
    const seed = [_]SimNote{.{ .start_ms = 0, .dur_ms = 100, .note = xyToMidiNote(.user1, 1, 2), .vel = 60 }};
    var out: std.ArrayList(SimNote) = .empty;
    defer out.deinit(a);

    // Flip horizontal + keep original
    try applyFlip(a, .{ .blob = "{\"number\":[1],\"umenu\":[0],\"pictctrl\":[1]}" }, .user1, &seed, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual([2]u8{ 1, 5 }, midiNoteToXY(.user1, out.items[1].note).?);

    // MidiTransform Rotate 90 CW: (1, 2) -> (2, 6)
    out.clearRetainingCapacity();
    const tr_params = [_]MxParam{.{ .index = 0, .kind = .enum_v, .value = 1 }};
    try applyMidiTransform(a, .{ .params = &tr_params }, .user1, &seed, &out);
    try std.testing.expectEqual([2]u8{ 2, 6 }, midiNoteToXY(.user1, out.items[0].note).?);

    // GridFilter allows only (row=1, col=2) -> x=2, y=1
    out.clearRetainingCapacity();
    try applyGridFilter(a, .{ .blob = "{\"matrixctrl\":[2,1,1, 0,0,0]}" }, .user1, &seed, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    // SetNotes overrides pitch & velocity
    out.clearRetainingCapacity();
    const sn_params = [_]MxParam{
        .{ .index = 0, .kind = .int, .value = 48 },
        .{ .index = 1, .kind = .int, .value = 99 },
    };
    try applySetNotes(a, .{ .blob = "{\"Set Pitch\":[1],\"Set Velocity\":[1]}", .params = &sn_params }, &seed, &out);
    try std.testing.expectEqual(@as(u8, 48), out.items[0].note);
    try std.testing.expectEqual(@as(u8, 99), out.items[0].vel);

    // Delay free ms = 250ms
    out.clearRetainingCapacity();
    try applyDelay(a, .{ .blob = "{\"live.text\":[1],\"Rate[2]\":[250],\"Rate[1]\":[100]}" }, 120.0, &seed, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 250.0), out.items[0].start_ms, 0.1);

    // Iris 3-color ramp at 50ms/step
    out.clearRetainingCapacity();
    try applyIris(a, .{ .blob = "{\"live.text[1]\":[1],\"Rate[2]\":[50],\"live.text\":[1],\"table\":[5,0,21,45]}" }, 120.0, &seed, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u8, 5), out.items[0].vel);
    try std.testing.expectEqual(@as(u8, 21), out.items[1].vel);
    try std.testing.expectEqual(@as(u8, 45), out.items[2].vel);
    try std.testing.expect(out.items[0].loop);

    // Resonator 1 right beam from (1, 2) -> cols 2,3,4,5,6,7 (6 pads)
    out.clearRetainingCapacity();
    try applyResonator(a, .resonator1, .{ .blob = "{\"pictctrl[9]\":[1],\"live.dial[1]\":[40],\"live.dial\":[80]}" }, .user1, 120.0, &seed, &out);
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0), out.items[5].start_ms, 0.1);
}

test "m4l: custom Max palette parser" {
    const txt =
        \\0, 0 0 0;
        \\1, 63 0 0;
        \\2, 0 63 0;
        \\3, 0 0 63;
        \\4, 63 63 0;
        \\5, 63 0 63;
        \\6, 0 63 63;
        \\7, 63 63 63;
    ;
    const tbl = parsePaletteFile(txt) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), tbl[1]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), tbl[2]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), tbl[3]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), tbl[7]);
}

test "m4l: classic Midi Extension BPM numboxes do not trigger MIDIext5 loop/mask" {
    const legacy_params = [_]MxParam{
        .{ .index = 0, .kind = .float, .name = "live.numbox", .value = 120.0 },
        .{ .index = 1, .kind = .float, .name = "live.numbox[1]", .value = 120.0 },
    };
    const legacy = parseGenericMidiExtSettings(.{
        .patch_name = "Midi Extension.amxd",
        .params = &legacy_params,
    });
    try std.testing.expect(!legacy.is_mask);
    try std.testing.expect(!legacy.loop);

    const v5_params = [_]MxParam{
        .{ .index = 0, .kind = .enum_v, .name = "Mode", .value = 1.0 },
        .{ .index = 1, .kind = .float, .name = "Loop", .value = 1.0 },
    };
    const v5 = parseGenericMidiExtSettings(.{
        .patch_name = "MIDIext5.0.amxd",
        .params = &v5_params,
    });
    try std.testing.expect(v5.is_mask);
    try std.testing.expect(v5.loop);
}
