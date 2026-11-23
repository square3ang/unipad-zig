//! Ableton Live (.als) Launchpad project converter & direct loader.
//! Streams gzip-compressed .als XML in pure Zig (no multi-hundred-MB DOM),
//! extracts Drum Rack + Instrument Rack samples (with Simpler trim & layer mix),
//! simulates MIDI Effect Rack lightshows (Pitch, Chord, Velocity, Note Length,
//! Arpeggiator, Launchpad S->RGB color mapping), and builds AutoPlay from
//! Arrangement MidiClips. Compiles on both desktop and wasm32-freestanding.
const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch.isWasm();
const c = if (is_wasm) struct {} else @import("c");
const decode = if (is_wasm) struct {} else @import("../audio/decode.zig");
const palette = @import("palette.zig");
const pack_mod = if (is_wasm) struct {} else @import("pack.zig");
const types = @import("types.zig");
const drums_bank = @import("drums_bank");

pub const VirtualFile = types.VirtualFile;
const UniPack = if (is_wasm) void else pack_mod.UniPack;
const SoundEntry = types.SoundEntry;
const LedEvent = types.LedEvent;
const LedAnimation = types.LedAnimation;
const AutoPlayEvent = types.AutoPlayEvent;

pub const ConvertSummary = struct {
    chains: u8,
    sounds: usize,
    led_pads: usize,
    led_events: usize,
    auto_events: usize,
};

pub const ConvertBufferResult = struct {
    title: []u8,
    zip: []u8,
    summary: ConvertSummary,
};

pub fn hasAls(files: []const VirtualFile) bool {
    return findAlsFile(files) != null;
}

fn findAlsFile(files: []const VirtualFile) ?VirtualFile {
    var best: ?VirtualFile = null;
    var best_depth: usize = std.math.maxInt(usize);
    for (files) |f| {
        if (!endsWithIgnoreCase(f.rel_path, ".als")) continue;
        if (std.mem.startsWith(u8, basenameOf(f.rel_path), "._")) continue;
        const depth = std.mem.count(u8, f.rel_path, "/");
        if (best == null or depth < best_depth or (depth == best_depth and f.bytes.len > best.?.bytes.len)) {
            best = f;
            best_depth = depth;
        }
    }
    return best;
}

// ============================================================================
// Public entry points
// ============================================================================

/// Loads an Ableton Live project directly into a playable UniPack in memory.
pub fn loadFromFiles(
    gpa: std.mem.Allocator,
    files: []const VirtualFile,
    sample_rate: u32,
    fallback_title: []const u8,
) !*UniPack {
    var work_arena = std.heap.ArenaAllocator.init(gpa);
    defer work_arena.deinit();
    const wa = work_arena.allocator();

    const proj = try buildProject(wa, files, fallback_title);

    const pk = try gpa.create(UniPack);
    pk.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    errdefer {
        pk.deinit();
        gpa.destroy(pk);
    }
    const pa = pk.arena.allocator();

    pk.title = try pa.dupe(u8, proj.title);
    pk.producer = try pa.dupe(u8, proj.producer);
    pk.button_x = 8;
    pk.button_y = 8;
    pk.chain_count = proj.chain_count;
    pk.square_button = true;
    pk.from_ableton = true;

    // Decode deduplicated audio samples into PCM
    var decoded = try gpa.alloc(decode.Sample, proj.raw_sounds.len);
    for (decoded) |*s| s.* = .{};
    errdefer {
        for (decoded) |s| if (s.data.len > 0) gpa.free(s.data);
        gpa.free(decoded);
    }
    for (proj.raw_sounds, 0..) |rs, i| {
        decoded[i] = decode.decode(gpa, rs.bytes, rs.rel_path, sample_rate) catch |err| blk: {
            std.log.warn("ableton: failed to decode {s}: {t}", .{ rs.rel_path, err });
            break :blk .{};
        };
    }
    pk.samples = decoded;

    // Copy sound table into pack arena
    const total_cells = @as(usize, proj.chain_count) * 64;
    pk.sound_table = try pa.alloc([]const SoundEntry, total_cells);
    var sound_mappings: usize = 0;
    for (0..total_cells) |ci| {
        const src = proj.sound_cells[ci];
        if (src.len == 0) {
            pk.sound_table[ci] = &.{};
        } else {
            pk.sound_table[ci] = try pa.dupe(SoundEntry, src);
            sound_mappings += src.len;
        }
    }
    pk.sound_count = sound_mappings;

    // Copy LED table into pack arena
    pk.led_table = try pa.alloc([]const LedAnimation, total_cells);
    var led_count: usize = 0;
    for (0..total_cells) |ci| {
        const anim_list = proj.led_cells[ci];
        if (anim_list.len == 0) {
            pk.led_table[ci] = &.{};
        } else {
            const anims = try pa.alloc(LedAnimation, anim_list.len);
            for (anim_list, 0..) |evs, k| {
                anims[k] = .{ .events = try pa.dupe(LedEvent, evs), .loop = 1 };
            }
            pk.led_table[ci] = anims;
            led_count += anim_list.len;
        }
    }
    pk.led_count = led_count;

    // Copy AutoPlay events
    pk.auto_play = try pa.dupe(AutoPlayEvent, proj.auto_play);

    return pk;
}

/// Converts in-memory Ableton project files into a portable UniPack .zip byte buffer (pure Zig, WASM-safe).
pub fn convertFilesToUniPackZipBuffer(
    gpa: std.mem.Allocator,
    files: []const VirtualFile,
    fallback_title: []const u8,
) !ConvertBufferResult {
    var work_arena = std.heap.ArenaAllocator.init(gpa);
    defer work_arena.deinit();
    const wa = work_arena.allocator();

    const proj = try buildProject(wa, files, fallback_title);

    var zw: ZipBufWriter = .{};
    defer zw.deinit(gpa);
    const summary = try emitUniPackEntries(wa, &proj, &zw, gpa);
    try zw.finish(gpa);

    const title_copy = try gpa.dupe(u8, proj.title);
    errdefer gpa.free(title_copy);
    const zip_bytes = try zw.buf.toOwnedSlice(gpa);
    return .{
        .title = title_copy,
        .zip = zip_bytes,
        .summary = summary,
    };
}

/// Converts an Ableton project (.zip, folder, or .als file) into a standard UniPack .zip archive.
pub fn convertToUniPackZip(
    gpa: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    output_zip_path: []const u8,
) !ConvertSummary {
    var work_arena = std.heap.ArenaAllocator.init(gpa);
    defer work_arena.deinit();
    const wa = work_arena.allocator();

    const files = try pack_mod.collectInputFiles(wa, io, input_path);
    const fallback = stemOfPath(input_path);
    const proj = try buildProject(wa, files, fallback);

    const arch = c.archive_write_new() orelse return error.ArchiveInitFailed;
    defer _ = c.archive_write_free(arch);
    if (c.archive_write_set_format_zip(arch) != c.ARCHIVE_OK) return error.ArchiveInitFailed;

    const out_z = try wa.dupeSentinel(u8, output_zip_path, 0);
    if (c.archive_write_open_filename(arch, out_z.ptr) != c.ARCHIVE_OK) return error.ArchiveOpenFailed;
    defer _ = c.archive_write_close(arch);

    var sink = LibArchiveSink{ .arch = arch };
    return try emitUniPackEntries(wa, &proj, &sink, wa);
}

const LibArchiveSink = struct {
    arch: *c.archive,
    fn writeEntry(self: *LibArchiveSink, a: std.mem.Allocator, rel_path: []const u8, data: []const u8) !void {
        try writeZipEntry(a, self.arch, rel_path, data);
    }
};

const ZipBufWriter = struct {
    const EntryMeta = struct {
        name: []u8,
        crc: u32,
        size: u32,
        offset: u32,
    };

    buf: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(EntryMeta) = .empty,

    fn deinit(self: *ZipBufWriter, a: std.mem.Allocator) void {
        for (self.entries.items) |e| a.free(e.name);
        self.entries.deinit(a);
        self.buf.deinit(a);
    }

    fn writeEntry(self: *ZipBufWriter, a: std.mem.Allocator, rel_path: []const u8, data: []const u8) !void {
        if (rel_path.len > std.math.maxInt(u16)) return error.NameTooLong;
        if (self.buf.items.len > std.math.maxInt(u32) or data.len > std.math.maxInt(u32)) return error.ZipTooLarge;
        const offset: u32 = @intCast(self.buf.items.len);
        const size: u32 = @intCast(data.len);
        const crc: u32 = std.hash.Crc32.hash(data);
        const name_len: u16 = @intCast(rel_path.len);

        // Local file header (STORE, UTF-8 flag bit 11 = 0x0800)
        var hdr: [30]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], 0x04034b50, .little);
        std.mem.writeInt(u16, hdr[4..6], 20, .little);
        std.mem.writeInt(u16, hdr[6..8], 0x0800, .little);
        std.mem.writeInt(u16, hdr[8..10], 0, .little); // STORE
        std.mem.writeInt(u16, hdr[10..12], 0, .little);
        std.mem.writeInt(u16, hdr[12..14], 0x5421, .little);
        std.mem.writeInt(u32, hdr[14..18], crc, .little);
        std.mem.writeInt(u32, hdr[18..22], size, .little);
        std.mem.writeInt(u32, hdr[22..26], size, .little);
        std.mem.writeInt(u16, hdr[26..28], name_len, .little);
        std.mem.writeInt(u16, hdr[28..30], 0, .little);

        try self.buf.ensureUnusedCapacity(a, hdr.len + rel_path.len + data.len);
        self.buf.appendSliceAssumeCapacity(&hdr);
        self.buf.appendSliceAssumeCapacity(rel_path);
        self.buf.appendSliceAssumeCapacity(data);

        const name_copy = try a.dupe(u8, rel_path);
        errdefer a.free(name_copy);
        try self.entries.append(a, .{
            .name = name_copy,
            .crc = crc,
            .size = size,
            .offset = offset,
        });
    }

    fn finish(self: *ZipBufWriter, a: std.mem.Allocator) !void {
        if (self.buf.items.len > std.math.maxInt(u32)) return error.ZipTooLarge;
        const cd_offset: u32 = @intCast(self.buf.items.len);
        for (self.entries.items) |e| {
            const name_len: u16 = @intCast(e.name.len);
            var ch: [46]u8 = undefined;
            std.mem.writeInt(u32, ch[0..4], 0x02014b50, .little);
            std.mem.writeInt(u16, ch[4..6], 20, .little);
            std.mem.writeInt(u16, ch[6..8], 20, .little);
            std.mem.writeInt(u16, ch[8..10], 0x0800, .little);
            std.mem.writeInt(u16, ch[10..12], 0, .little); // STORE
            std.mem.writeInt(u16, ch[12..14], 0, .little);
            std.mem.writeInt(u16, ch[14..16], 0x5421, .little);
            std.mem.writeInt(u32, ch[16..20], e.crc, .little);
            std.mem.writeInt(u32, ch[20..24], e.size, .little);
            std.mem.writeInt(u32, ch[24..28], e.size, .little);
            std.mem.writeInt(u16, ch[28..30], name_len, .little);
            std.mem.writeInt(u16, ch[30..32], 0, .little);
            std.mem.writeInt(u16, ch[32..34], 0, .little);
            std.mem.writeInt(u16, ch[34..36], 0, .little);
            std.mem.writeInt(u16, ch[36..38], 0, .little);
            std.mem.writeInt(u32, ch[38..42], 0, .little);
            std.mem.writeInt(u32, ch[42..46], e.offset, .little);
            try self.buf.ensureUnusedCapacity(a, ch.len + e.name.len);
            self.buf.appendSliceAssumeCapacity(&ch);
            self.buf.appendSliceAssumeCapacity(e.name);
        }
        const cd_size: u32 = @intCast(self.buf.items.len - cd_offset);
        const count: u16 = @intCast(@min(self.entries.items.len, std.math.maxInt(u16)));
        var eocd: [22]u8 = undefined;
        std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
        std.mem.writeInt(u16, eocd[4..6], 0, .little);
        std.mem.writeInt(u16, eocd[6..8], 0, .little);
        std.mem.writeInt(u16, eocd[8..10], count, .little);
        std.mem.writeInt(u16, eocd[10..12], count, .little);
        std.mem.writeInt(u32, eocd[12..16], cd_size, .little);
        std.mem.writeInt(u32, eocd[16..20], cd_offset, .little);
        std.mem.writeInt(u16, eocd[20..22], 0, .little);
        try self.buf.appendSlice(a, &eocd);
    }
};

fn emitUniPackEntries(
    wa: std.mem.Allocator,
    proj: *const ConvertedProject,
    sink: anytype,
    sink_alloc: std.mem.Allocator,
) !ConvertSummary {
    // 1. info
    const info_txt = try std.fmt.allocPrint(
        wa,
        "title={s}\nproducerName={s}\nbuttonX=8\nbuttonY=8\nchain={d}\nsquareButton=true\nlandscape=true\n",
        .{ proj.title, proj.producer, proj.chain_count },
    );
    try sink.writeEntry(sink_alloc, "info", info_txt);

    // 2. sounds/* + keySound
    var sound_names = try wa.alloc([]const u8, proj.raw_sounds.len);
    for (proj.raw_sounds, 0..) |rs, i| {
        const ext = extOf(rs.rel_path);
        const sname = try std.fmt.allocPrint(wa, "s_{d:0>4}{s}", .{ i, ext });
        sound_names[i] = sname;
        const zpath = try std.fmt.allocPrint(wa, "sounds/{s}", .{sname});
        try sink.writeEntry(sink_alloc, zpath, rs.bytes);
    }

    var ks_buf: std.ArrayList(u8) = .empty;
    var sound_mappings: usize = 0;
    for (0..proj.chain_count) |ch| {
        for (0..8) |r| {
            for (0..8) |col| {
                const cell = proj.sound_cells[(ch * 8 + r) * 8 + col];
                for (cell) |se| {
                    sound_mappings += 1;
                    const uni_loop: i32 = if (se.loop < 0) 0 else se.loop + 1;
                    try ks_buf.print(wa, "{d} {d} {d} {s}", .{ ch + 1, r + 1, col + 1, sound_names[se.sample_id] });
                    if (uni_loop != 1) try ks_buf.print(wa, " {d}", .{uni_loop});
                    try ks_buf.append(wa, '\n');
                }
            }
        }
    }
    try sink.writeEntry(sink_alloc, "keySound", ks_buf.items);

    // 3. keyLED/*
    var led_pads: usize = 0;
    var led_events: usize = 0;
    for (0..proj.chain_count) |ch| {
        for (0..8) |r| {
            for (0..8) |col| {
                const anim_list = proj.led_cells[(ch * 8 + r) * 8 + col];
                if (anim_list.len == 0) continue;
                led_pads += 1;
                for (anim_list, 0..) |evs, k| {
                    led_events += evs.len;
                    var lb: std.ArrayList(u8) = .empty;
                    for (evs) |ev| {
                        switch (ev) {
                            .pad_on => |on| {
                                if (on.color == palette.argbOf(on.velocity)) {
                                    try lb.print(wa, "on {d} {d} auto {d}\n", .{ on.row + 1, on.col + 1, on.velocity });
                                } else {
                                    try lb.print(wa, "on {d} {d} {x:0>6} {d}\n", .{ on.row + 1, on.col + 1, on.color & 0xFFFFFF, on.velocity });
                                }
                            },
                            .pad_off => |off| try lb.print(wa, "off {d} {d}\n", .{ off.row + 1, off.col + 1 }),
                            .ring_on => |on| {
                                if (on.idx == types.logo_led_index) {
                                    if (on.color == palette.argbOf(on.velocity)) {
                                        try lb.print(wa, "on l auto {d}\n", .{on.velocity});
                                    } else {
                                        try lb.print(wa, "on l {x:0>6} {d}\n", .{ on.color & 0xFFFFFF, on.velocity });
                                    }
                                } else {
                                    if (on.color == palette.argbOf(on.velocity)) {
                                        try lb.print(wa, "on mc {d} auto {d}\n", .{ on.idx + 1, on.velocity });
                                    } else {
                                        try lb.print(wa, "on mc {d} {x:0>6} {d}\n", .{ on.idx + 1, on.color & 0xFFFFFF, on.velocity });
                                    }
                                }
                            },
                            .ring_off => |idx| {
                                if (idx == types.logo_led_index) {
                                    try lb.appendSlice(wa, "off l\n");
                                } else {
                                    try lb.print(wa, "off mc {d}\n", .{idx + 1});
                                }
                            },
                            .delay => |d| try lb.print(wa, "delay {d}\n", .{d}),
                            .chain => {},
                        }
                    }
                    const lpath = if (anim_list.len == 1)
                        try std.fmt.allocPrint(wa, "keyLED/{d} {d} {d} 1", .{ ch + 1, r + 1, col + 1 })
                    else
                        try std.fmt.allocPrint(wa, "keyLED/{d} {d} {d} 1 {c}", .{ ch + 1, r + 1, col + 1, @as(u8, 'a') + @as(u8, @intCast(@min(k, 25))) });
                    try sink.writeEntry(sink_alloc, lpath, lb.items);
                }
            }
        }
    }

    // 4. autoPlay
    if (proj.auto_play.len > 0) {
        var ab: std.ArrayList(u8) = .empty;
        for (proj.auto_play) |ev| {
            switch (ev) {
                .chain => |ch| try ab.print(wa, "chain {d}\n", .{ch + 1}),
                .on => |o| try ab.print(wa, "on {d} {d}\n", .{ o.row + 1, o.col + 1 }),
                .off => |o| try ab.print(wa, "off {d} {d}\n", .{ o.row + 1, o.col + 1 }),
                .delay => |d| try ab.print(wa, "delay {d}\n", .{d}),
            }
        }
        try sink.writeEntry(sink_alloc, "autoPlay", ab.items);
    }

    return .{
        .chains = proj.chain_count,
        .sounds = sound_mappings,
        .led_pads = led_pads,
        .led_events = led_events,
        .auto_events = proj.auto_play.len,
    };
}

fn writeZipEntry(a: std.mem.Allocator, arch: *c.archive, rel_path: []const u8, data: []const u8) !void {
    const entry = c.archive_entry_new() orelse return error.OutOfMemory;
    defer c.archive_entry_free(entry);
    const path_z = try a.dupeSentinel(u8, rel_path, 0);
    c.archive_entry_set_pathname(entry, path_z.ptr);
    c.archive_entry_set_size(entry, @intCast(data.len));
    c.archive_entry_set_filetype(entry, 0o100000); // AE_IFREG
    c.archive_entry_set_perm(entry, 0o644);
    if (c.archive_write_header(arch, entry) != c.ARCHIVE_OK) return error.ArchiveWriteFailed;
    if (data.len > 0) {
        const written = c.archive_write_data(arch, data.ptr, data.len);
        if (written < 0 or @as(usize, @intCast(written)) != data.len) return error.ArchiveWriteFailed;
    }
}

// ============================================================================
// Intermediate Ableton IR & Project Builder
// ============================================================================

const ConvertedProject = struct {
    title: []const u8,
    producer: []const u8,
    chain_count: u8,
    raw_sounds: []const VirtualFile,
    sound_cells: [][]const SoundEntry,
    led_cells: [][]const []const LedEvent,
    auto_play: []const AutoPlayEvent,
};

const PadMapping = struct {
    midi_note: u8,
    sel_min: u8,
    sel_max: u8,
    key_min: u8 = 0,
    key_max: u8 = 127,
    rel_path: []const u8,
    file_name: []const u8,
    loop: bool,
    sample_start: u64 = 0,
    sample_end: u64 = 0,
    default_duration: u64 = 0,
    default_sample_rate: u32 = 0,
};

const MidiDevKind = enum { rack, pitcher, chord, velocity, note_length, arp, random, mx_ext };

const MidiDev = union(MidiDevKind) {
    rack: struct { on: bool = true, rack_idx: u32 },
    pitcher: struct { on: bool = true, pitch: i16 = 0, lowest: u8 = 0, range: u8 = 127 },
    chord: struct { on: bool = true, shifts: [6]i8 = @splat(0), vels: [6]f32 = @splat(1.0) },
    velocity: struct { on: bool = true, mode: u8 = 0, operation: u8 = 0, min_out: u8 = 1, max_out: u8 = 127, lowest: u8 = 1, range: u8 = 127 },
    note_length: struct { on: bool = true, trigger_off: bool = false, sync_state: bool = false, synced_len: u8 = 4, time_ms: f32 = 200.0, gate: f32 = 100.0 },
    arp: struct {
        on: bool = true,
        mode: u8 = 0,
        sync_state: bool = true,
        synced_rate: u8 = 3,
        free_rate_ms: f32 = 20.0,
        repeat_count: u8 = 1,
        gate: f32 = 100.0,
        transpose_steps: u8 = 0,
        transpose_dist: i8 = 12,
    },
    random: struct {
        on: bool = true,
        chance: f32 = 0.0,
        choices: u8 = 12,
        scale: u8 = 1,
        sign: u8 = 0,
        alternate: bool = false,
    },
    mx_ext: struct { on: bool = true, lom_id: u32 = 0 },
};

const MidiBranch = struct {
    key_min: u8 = 0,
    key_max: u8 = 127,
    sel_min: u8 = 0,
    sel_max: u8 = 127,
    has_sel: bool = false,
    muted: bool = false,
    devs: std.ArrayList(MidiDev) = .empty,
};

const MidiRack = struct {
    on: bool = true,
    branches: std.ArrayList(u32) = .empty, // indices into ParsedAls.midi_branches
};

const ClipNote = struct {
    beat: f64,
    dur: f64,
    midi_key: u8,
};

const ArrClip = struct {
    name: []const u8 = "",
    start_beat: f64 = 0,
    end_beat: f64 = 0,
    loop_start: f64 = 0,
    notes: std.ArrayList(ClipNote) = .empty,
};

const LightMode = enum(u8) { static, pulse, flash };

const LightRootRack = struct {
    rack_idx: u32,
    mode: LightMode = .static,
    legacy_rg: bool = false,
};

const ParsedAls = struct {
    major_version: u16 = 5,
    tempo: f64 = 120.0,
    pad_samples: std.ArrayList(PadMapping) = .empty,
    midi_racks: std.ArrayList(MidiRack) = .empty,
    midi_branches: std.ArrayList(MidiBranch) = .empty,
    light_root_racks: std.ArrayList(LightRootRack) = .empty,
    arr_clips: std.ArrayList(ArrClip) = .empty,
    max_chain_seen: u8 = 0,
};

const NoteLayout = enum { user1, programmer };

fn buildProject(a: std.mem.Allocator, files: []const VirtualFile, fallback_title: []const u8) !ConvertedProject {
    const als_file = findAlsFile(files) orelse return error.MissingAlsFile;
    var parsed: ParsedAls = .{};
    try parseAlsGzipStream(a, als_file.bytes, &parsed);

    const title = blk: {
        const stem = stemOfPath(als_file.rel_path);
        if (stem.len > 0) break :blk try a.dupe(u8, stem);
        break :blk if (fallback_title.len > 0) try a.dupe(u8, fallback_title) else "Ableton Project";
    };

    const layout = detectLayout(parsed.pad_samples.items);
    const chain_count: u8 = @intCast(std.math.clamp(@as(usize, parsed.max_chain_seen) + 1, 1, types.max_chains));
    const total_cells = @as(usize, chain_count) * 64;

    // Index all audio files in the zip/folder by normalized lowercase path and unique basename
    var path_index = std.StringHashMapUnmanaged(VirtualFile).empty;
    var base_index = std.StringHashMapUnmanaged(?VirtualFile).empty;
    for (files) |f| {
        if (!isAudioFile(f.rel_path)) continue;
        const low_full = try lowerAlloc(a, f.rel_path);
        try path_index.put(a, low_full, f);
        const low_base = try lowerAlloc(a, basenameOf(f.rel_path));
        const gop = try base_index.getOrPut(a, low_base);
        if (!gop.found_existing) {
            gop.value_ptr.* = f;
        } else {
            // Multiple files share this basename: mark ambiguous so fallback won't pick the wrong one.
            gop.value_ptr.* = null;
        }
    }

    // Deduplicate resolved (and optionally trimmed) sound files -> sample_id
    var raw_sounds: std.ArrayList(VirtualFile) = .empty;
    var file_to_id = std.StringHashMapUnmanaged(u32).empty;

    const CellLayer = struct {
        entry: SoundEntry,
        key_min: u8 = 0,
        key_max: u8 = 127,
    };

    var sound_lists = try a.alloc(std.ArrayList(CellLayer), total_cells);
    for (sound_lists) |*l| l.* = .empty;

    var missing_samples: std.ArrayList(PadMapping) = .empty;

    for (parsed.pad_samples.items) |pm| {
        const xy = midiNoteToXY(layout, pm.midi_note) orelse continue;
        const orig_vf = resolveSampleFile(a, pm.rel_path, pm.file_name, files, &path_index, &base_index) orelse {
            try missing_samples.append(a, pm);
            continue;
        };

        const trimmed = shouldTrimSample(pm, orig_vf);
        const low_path = try lowerAlloc(a, orig_vf.rel_path);
        const key = if (trimmed)
            try std.fmt.allocPrint(a, "{s}#{d}..{d}", .{ low_path, pm.sample_start, pm.sample_end })
        else
            low_path;

        const sample_id: u32 = if (file_to_id.get(key)) |existing| existing else blk: {
            const vf = if (trimmed)
                (try trimSampleFile(a, orig_vf, pm.sample_start, pm.sample_end, pm.default_sample_rate)) orelse orig_vf
            else
                orig_vf;
            const id: u32 = @intCast(raw_sounds.items.len);
            try raw_sounds.append(a, vf);
            try file_to_id.put(a, key, id);
            break :blk id;
        };

        const c_min = @min(pm.sel_min, chain_count - 1);
        const c_max = @min(pm.sel_max, chain_count - 1);
        if (c_min > c_max) continue;
        var ch: u8 = c_min;
        while (ch <= c_max) : (ch += 1) {
            const ci = (@as(usize, ch) * 8 + xy[0]) * 8 + xy[1];
            // Deduplicate identical sample in the same key-zone (e.g. accidental duplicate branches).
            var dup = false;
            for (sound_lists[ci].items) |prev| {
                if (prev.entry.sample_id == sample_id and prev.key_min == pm.key_min and prev.key_max == pm.key_max) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                try sound_lists[ci].append(a, .{
                    .entry = .{
                        .sample_id = sample_id,
                        .loop = if (pm.loop) -1 else 0,
                        .wormhole = null,
                    },
                    .key_min = pm.key_min,
                    .key_max = pm.key_max,
                });
            }
        }
    }

    // Pass 2: Fallback for missing Ableton Core Library drum samples (e.g. uncollected Kick-LD / Snare-909).
    // Uses embedded Public Domain LinnDrum LM-2 & GPLv2+ LMMS one-shots matched by machine/drum type.
    for (missing_samples.items) |pm| {
        const xy = midiNoteToXY(layout, pm.midi_note) orelse continue;
        const asset = drums_bank.lookup(pm.rel_path, pm.file_name) orelse {
            if (!is_wasm) std.log.warn("ableton: missing sample \"{s}/{s}\" (not in project)", .{ pm.rel_path, pm.file_name });
            continue;
        };
        const vf: VirtualFile = .{ .rel_path = asset.name, .bytes = asset.bytes };
        const key = try lowerAlloc(a, vf.rel_path);
        const sample_id: u32 = if (file_to_id.get(key)) |existing| existing else blk: {
            const new_id: u32 = @intCast(raw_sounds.items.len);
            try raw_sounds.append(a, vf);
            try file_to_id.put(a, key, new_id);
            if (!is_wasm) std.log.warn("ableton: missing factory drum \"{s}/{s}\" -> bundled \"{s}\"", .{ pm.rel_path, pm.file_name, vf.rel_path });
            break :blk new_id;
        };

        const c_min = @min(pm.sel_min, chain_count - 1);
        const c_max = @min(pm.sel_max, chain_count - 1);
        if (c_min > c_max) continue;
        var ch: u8 = c_min;
        while (ch <= c_max) : (ch += 1) {
            const ci = (@as(usize, ch) * 8 + xy[0]) * 8 + xy[1];
            // Only fill empty cells so we don't duplicate pads that already have a real bundled layer.
            if (sound_lists[ci].items.len == 0) {
                try sound_lists[ci].append(a, .{
                    .entry = .{
                        .sample_id = sample_id,
                        .loop = if (pm.loop) -1 else 0,
                        .wormhole = null,
                    },
                    .key_min = pm.key_min,
                    .key_max = pm.key_max,
                });
            }
        }
    }

    // Pass 3: Partition each cell by overlapping KeyRange.
    // - Overlapping KeyRanges (e.g. sibling InstrumentBranches all 0..127) play simultaneously -> mix WAVs into 1 entry.
    // - Disjoint KeyRanges (e.g. MidiRandom Alternate 60..60, 61..61, ...) cycle sequentially -> keep separate keySound entries.
    const sound_cells = try a.alloc([]const SoundEntry, total_cells);
    var group_buf: std.ArrayList(SoundEntry) = .empty;
    defer group_buf.deinit(a);
    var used_buf: std.ArrayList(bool) = .empty;
    defer used_buf.deinit(a);

    for (0..total_cells) |ci| {
        const layers = sound_lists[ci].items;
        if (layers.len == 0) {
            sound_cells[ci] = &.{};
            continue;
        }
        if (layers.len == 1) {
            const one = try a.alloc(SoundEntry, 1);
            one[0] = layers[0].entry;
            sound_cells[ci] = one;
            continue;
        }

        used_buf.clearRetainingCapacity();
        try used_buf.appendNTimes(a, false, layers.len);
        var cell_out: std.ArrayList(SoundEntry) = .empty;

        for (0..layers.len) |i| {
            if (used_buf.items[i]) continue;
            used_buf.items[i] = true;
            group_buf.clearRetainingCapacity();
            try group_buf.append(a, layers[i].entry);
            var g_min = layers[i].key_min;
            var g_max = layers[i].key_max;

            for (i + 1..layers.len) |j| {
                if (used_buf.items[j]) continue;
                if (layers[j].key_min <= g_max and g_min <= layers[j].key_max) {
                    used_buf.items[j] = true;
                    g_min = @max(g_min, layers[j].key_min);
                    g_max = @min(g_max, layers[j].key_max);
                    try group_buf.append(a, layers[j].entry);
                }
            }

            if (group_buf.items.len > 1) {
                if (try mixWavLayers(a, raw_sounds.items, group_buf.items)) |mixed_wav| {
                    var any_loop = false;
                    for (group_buf.items) |se| if (se.loop < 0) {
                        any_loop = true;
                    };
                    const mixed_id: u32 = @intCast(raw_sounds.items.len);
                    const lname = try std.fmt.allocPrint(a, "layer_{d}_{d}.wav", .{ ci, i });
                    try raw_sounds.append(a, .{ .rel_path = lname, .bytes = mixed_wav });
                    try cell_out.append(a, .{
                        .sample_id = mixed_id,
                        .loop = if (any_loop) -1 else 0,
                        .wormhole = null,
                    });
                } else {
                    try cell_out.appendSlice(a, group_buf.items);
                }
            } else {
                try cell_out.append(a, group_buf.items[0]);
            }
        }
        sound_cells[ci] = cell_out.items;
    }

    // Simulate MIDI Effect Rack lightshows (including MIDI Extension 0save + .mid and MidiRandom multi-press)
    const led_cells = try a.alloc([]const []const LedEvent, total_cells);
    for (led_cells) |*c_evs| c_evs.* = &.{};

    if (parsed.light_root_racks.items.len > 0) {
        var midiext = try buildMidiExtCtx(a, files);
        const beat_ms = 60000.0 / std.math.clamp(parsed.tempo, 20.0, 400.0);
        for (0..chain_count) |ch_usize| {
            const ch: u8 = @intCast(ch_usize);
            for (0..8) |r_u| {
                for (0..8) |col_u| {
                    const row: u8 = @intCast(r_u);
                    const col: u8 = @intCast(col_u);
                    const trig_note = xyToMidiNote(layout, row, col);
                    const anims = try simulatePadLights(a, &parsed, &midiext, layout, beat_ms, ch, trig_note);
                    led_cells[(ch_usize * 8 + r_u) * 8 + col_u] = anims;
                }
            }
        }
    }

    // Build AutoPlay from Arrangement MidiClips
    const auto_play = try buildAutoPlay(a, &parsed, layout, chain_count);

    return .{
        .title = title,
        .producer = "Ableton Live Import",
        .chain_count = chain_count,
        .raw_sounds = raw_sounds.items,
        .sound_cells = sound_cells,
        .led_cells = led_cells,
        .auto_play = auto_play,
    };
}

// ============================================================================
// Streaming Gzip + XML Parser for .als (handles 250MB+ XML in constant memory)
// ============================================================================

const Tag = enum(u8) {
    other,
    master_track,
    tempo,
    midi_track,
    ableton,
    return_track,
    drum_group_device,
    drum_branch,
    receiving_note,
    instrument_group_device,
    instrument_branch,
    branch_selector_range,
    original_simpler,
    multi_sampler,
    sample_start,
    sample_end,
    sample_ref,
    default_duration,
    default_sample_rate,
    file_ref,
    relative_path,
    relative_path_element,
    sustain_loop,
    loop_on,
    midi_effect_group_device,
    midi_effect_branch,
    key_range,
    mixer_device,
    speaker,
    midi_pitcher,
    midi_chord,
    midi_velocity,
    midi_note_length,
    midi_arpeggiator,
    midi_random,
    chance,
    choices,
    scale,
    sign,
    alternate,
    mx_device_midi_effect,
    lom_id,
    on,
    pitch,
    lowest,
    range,
    shift1,
    shift2,
    shift3,
    shift4,
    shift5,
    shift6,
    velocity1,
    velocity2,
    velocity3,
    velocity4,
    velocity5,
    velocity6,
    operation,
    min_out,
    max_out,
    mode,
    sync_state,
    synced_length,
    time_length,
    gate,
    synced_rate,
    free_rate,
    repeat_count,
    hold,
    transpose_steps,
    transpose_distance,
    clip_timeable,
    arranger_automation,
    midi_clip,
    current_start,
    current_end,
    loop,
    loop_start,
    key_track,
    midi_key,
    midi_note_event,
    name,
    midi_output_routing,
    target,
    min,
    max,
    manual,
};

const tag_map = std.StaticStringMap(Tag).initComptime(.{
    .{ "Ableton", .ableton },
    .{ "MasterTrack", .master_track },
    .{ "MainTrack", .master_track },
    .{ "Tempo", .tempo },
    .{ "MidiTrack", .midi_track },
    .{ "ReturnTrack", .return_track },
    .{ "DrumGroupDevice", .drum_group_device },
    .{ "DrumBranch", .drum_branch },
    .{ "ReceivingNote", .receiving_note },
    .{ "InstrumentGroupDevice", .instrument_group_device },
    .{ "InstrumentBranch", .instrument_branch },
    .{ "BranchSelectorRange", .branch_selector_range },
    .{ "OriginalSimpler", .original_simpler },
    .{ "MultiSampler", .multi_sampler },
    .{ "SampleStart", .sample_start },
    .{ "SampleEnd", .sample_end },
    .{ "SampleRef", .sample_ref },
    .{ "DefaultDuration", .default_duration },
    .{ "DefaultSampleRate", .default_sample_rate },
    .{ "FileRef", .file_ref },
    .{ "RelativePath", .relative_path },
    .{ "RelativePathElement", .relative_path_element },
    .{ "SustainLoop", .sustain_loop },
    .{ "LoopOn", .loop_on },
    .{ "MidiEffectGroupDevice", .midi_effect_group_device },
    .{ "MidiEffectBranch", .midi_effect_branch },
    .{ "KeyRange", .key_range },
    .{ "MixerDevice", .mixer_device },
    .{ "Speaker", .speaker },
    .{ "MidiPitcher", .midi_pitcher },
    .{ "MidiChord", .midi_chord },
    .{ "MidiVelocity", .midi_velocity },
    .{ "MidiNoteLength", .midi_note_length },
    .{ "MidiArpeggiator", .midi_arpeggiator },
    .{ "MidiRandom", .midi_random },
    .{ "Chance", .chance },
    .{ "Choices", .choices },
    .{ "Scale", .scale },
    .{ "Sign", .sign },
    .{ "Alternate", .alternate },
    .{ "MxDeviceMidiEffect", .mx_device_midi_effect },
    .{ "LomId", .lom_id },
    .{ "On", .on },
    .{ "Pitch", .pitch },
    .{ "Lowest", .lowest },
    .{ "Range", .range },
    .{ "Shift1", .shift1 },
    .{ "Shift2", .shift2 },
    .{ "Shift3", .shift3 },
    .{ "Shift4", .shift4 },
    .{ "Shift5", .shift5 },
    .{ "Shift6", .shift6 },
    .{ "Velocity1", .velocity1 },
    .{ "Velocity2", .velocity2 },
    .{ "Velocity3", .velocity3 },
    .{ "Velocity4", .velocity4 },
    .{ "Velocity5", .velocity5 },
    .{ "Velocity6", .velocity6 },
    .{ "Operation", .operation },
    .{ "MinOut", .min_out },
    .{ "MaxOut", .max_out },
    .{ "Mode", .mode },
    .{ "SyncState", .sync_state },
    .{ "SyncedLength", .synced_length },
    .{ "TimeLength", .time_length },
    .{ "Gate", .gate },
    .{ "SyncedRate", .synced_rate },
    .{ "FreeRate", .free_rate },
    .{ "RepeatCount", .repeat_count },
    .{ "Hold", .hold },
    .{ "TransposeSteps", .transpose_steps },
    .{ "TransposeDistance", .transpose_distance },
    .{ "ClipTimeable", .clip_timeable },
    .{ "ArrangerAutomation", .arranger_automation },
    .{ "MidiClip", .midi_clip },
    .{ "CurrentStart", .current_start },
    .{ "CurrentEnd", .current_end },
    .{ "Loop", .loop },
    .{ "LoopStart", .loop_start },
    .{ "KeyTrack", .key_track },
    .{ "MidiKey", .midi_key },
    .{ "MidiNoteEvent", .midi_note_event },
    .{ "Name", .name },
    .{ "MidiOutputRouting", .midi_output_routing },
    .{ "Target", .target },
    .{ "Min", .min },
    .{ "Max", .max },
    .{ "Manual", .manual },
});

const InstBranchFrame = struct {
    sample_start: usize = 0,
    sel_min: u8 = 0,
    sel_max: u8 = 0,
    key_min: u8 = 0,
    key_max: u8 = 127,
    muted: bool = false,
};

const ParserState = struct {
    a: std.mem.Allocator,
    out: *ParsedAls,

    stack: [192]Tag = @splat(.other),
    depth: usize = 0,

    // Context flags
    in_master: bool = false,
    in_midi_track: bool = false,
    in_return_track: bool = false,
    track_has_drum: bool = false,

    // Sample extraction state (DrumGroup -> DrumBranch -> [InstrumentBranch...] -> Simpler)
    in_drum_group: bool = false,
    in_drum_branch: bool = false,
    drum_branch_muted: bool = false,
    drum_branch_sample_start: usize = 0,
    cur_drum_note: u8 = 0,
    has_drum_note: bool = false,
    inst_stack: [8]InstBranchFrame = @splat(.{}),
    inst_depth: usize = 0,
    in_simpler: bool = false,
    in_sample_ref: bool = false,
    in_sample_file_ref: bool = false,
    simpler_on: bool = true,
    simpler_loop: bool = false,
    simpler_start: u64 = 0,
    simpler_end: u64 = 0,
    simpler_default_dur: u64 = 0,
    simpler_default_sr: u32 = 0,
    simpler_rel: std.ArrayList(u8) = .empty,
    simpler_name: []const u8 = "",

    // Recursive MIDI Effect Rack state
    rack_stack: [32]u32 = undefined,
    rack_depth: usize = 0,
    branch_stack: [32]u32 = undefined,
    branch_depth: usize = 0,
    active_dev_branch: ?u32 = null,
    active_dev_idx: usize = 0,
    active_dev_tag: Tag = .other,
    track_light_mode: LightMode = .static,
    track_legacy_rg: bool = false,
    track_root_racks: std.ArrayList(u32) = .empty,

    // Arrangement MidiClip state
    in_clip_timeable: bool = false,
    in_arranger_auto: bool = false,
    in_midi_clip: bool = false,
    cur_clip: ArrClip = .{},
    cur_clip_key: u8 = 0,
    clip_keytrack_start: usize = 0,
    has_clip_key: bool = false,
    track_clips: std.ArrayList(ArrClip) = .empty,

    fn parentTag(s: *const ParserState) Tag {
        return if (s.depth > 0) s.stack[s.depth - 1] else .other;
    }

    fn grandTag(s: *const ParserState) Tag {
        return if (s.depth > 1) s.stack[s.depth - 2] else .other;
    }

    fn onOpen(s: *ParserState, name: []const u8, attrs: []const u8, self_closing: bool) !void {
        const tag = tag_map.get(name) orelse .other;
        const parent = s.parentTag();
        const grand = s.grandTag();

        switch (tag) {
            .ableton => {
                if (attrInt(attrs, "MajorVersion")) |mv| {
                    if (mv > 0 and mv <= 65535) s.out.major_version = @intCast(mv);
                }
            },
            .master_track => s.in_master = true,
            .return_track => s.in_return_track = true,
            .midi_track => {
                s.in_midi_track = true;
                s.track_has_drum = false;
                s.track_light_mode = .static;
                s.track_legacy_rg = false;
                s.track_root_racks.clearRetainingCapacity();
                s.track_clips.clearRetainingCapacity();
            },
            .drum_group_device => {
                if (s.in_midi_track) {
                    s.in_drum_group = true;
                    s.track_has_drum = true;
                }
            },
            .drum_branch => {
                if (s.in_drum_group) {
                    s.in_drum_branch = true;
                    s.drum_branch_muted = false;
                    s.drum_branch_sample_start = s.out.pad_samples.items.len;
                    s.has_drum_note = false;
                    s.cur_drum_note = 0;
                }
            },
            .receiving_note => {
                if (s.in_drum_branch) {
                    if (attrInt(attrs, "Value")) |rv| {
                        const midi = 128 - rv;
                        if (midi >= 0 and midi <= 127) {
                            s.cur_drum_note = @intCast(midi);
                            s.has_drum_note = true;
                        }
                    }
                }
            },
            .instrument_branch => {
                if (s.in_midi_track and !s.in_return_track and s.inst_depth < s.inst_stack.len) {
                    s.inst_stack[s.inst_depth] = .{
                        .sample_start = s.out.pad_samples.items.len,
                    };
                    s.inst_depth += 1;
                }
            },
            .original_simpler, .multi_sampler => {
                if (s.in_drum_branch) {
                    s.in_simpler = true;
                    s.in_sample_ref = false;
                    s.in_sample_file_ref = false;
                    s.simpler_on = true;
                    s.simpler_loop = false;
                    s.simpler_start = 0;
                    s.simpler_end = 0;
                    s.simpler_default_dur = 0;
                    s.simpler_default_sr = 0;
                    s.simpler_rel.clearRetainingCapacity();
                    s.simpler_name = "";
                }
            },
            .sample_start => {
                if (s.in_simpler) {
                    if (attrU64(attrs, "Value")) |v| s.simpler_start = v;
                }
            },
            .sample_end => {
                if (s.in_simpler) {
                    if (attrU64(attrs, "Value")) |v| s.simpler_end = v;
                }
            },
            .sample_ref => {
                if (s.in_simpler) s.in_sample_ref = true;
            },
            .default_duration => {
                if (s.in_sample_ref) {
                    if (attrU64(attrs, "Value")) |v| s.simpler_default_dur = v;
                }
            },
            .default_sample_rate => {
                if (s.in_sample_ref) {
                    if (attrU64(attrs, "Value")) |v| {
                        if (v >= 8000 and v <= 384000) s.simpler_default_sr = @intCast(v);
                    }
                }
            },
            .file_ref => {
                if (s.in_sample_ref and parent == .sample_ref) s.in_sample_file_ref = true;
            },
            .relative_path => {
                // Live 9/10 uses child <RelativePathElement Dir="..."/>; Live 11/12 uses Value="..."
                if (s.in_sample_file_ref and parent == .file_ref) {
                    s.simpler_rel.clearRetainingCapacity();
                    if (attrStr(attrs, "Value")) |v| {
                        if (v.len > 0) try appendUnescaped(s.a, &s.simpler_rel, v);
                    }
                }
            },
            .relative_path_element => {
                if (s.in_sample_file_ref and parent == .relative_path) {
                    if (attrStr(attrs, "Dir")) |dir| {
                        if (dir.len > 0) {
                            if (s.simpler_rel.items.len > 0) try s.simpler_rel.append(s.a, '/');
                            try appendUnescaped(s.a, &s.simpler_rel, dir);
                        }
                    }
                }
            },
            .loop_on => {
                if (s.in_simpler and parent == .sustain_loop) {
                    if (attrStr(attrs, "Value")) |v| s.simpler_loop = std.mem.eql(u8, v, "true");
                }
            },
            .midi_effect_group_device => {
                if (s.in_midi_track and !s.in_return_track and !s.in_drum_group and s.rack_depth < s.rack_stack.len) {
                    const ridx: u32 = @intCast(s.out.midi_racks.items.len);
                    try s.out.midi_racks.append(s.a, .{});
                    if (s.branch_depth > 0) {
                        const bidx = s.branch_stack[s.branch_depth - 1];
                        try s.out.midi_branches.items[bidx].devs.append(s.a, .{ .rack = .{ .on = true, .rack_idx = ridx } });
                    } else if (s.rack_depth == 0) {
                        try s.track_root_racks.append(s.a, ridx);
                    }
                    s.rack_stack[s.rack_depth] = ridx;
                    s.rack_depth += 1;
                    s.active_dev_tag = .midi_effect_group_device;
                }
            },
            .midi_effect_branch => {
                if (s.rack_depth > 0 and s.branch_depth < s.branch_stack.len) {
                    const bidx: u32 = @intCast(s.out.midi_branches.items.len);
                    try s.out.midi_branches.append(s.a, .{});
                    const ridx = s.rack_stack[s.rack_depth - 1];
                    try s.out.midi_racks.items[ridx].branches.append(s.a, bidx);
                    s.branch_stack[s.branch_depth] = bidx;
                    s.branch_depth += 1;
                }
            },
            .midi_pitcher => try s.pushMidiDev(.{ .pitcher = .{} }, .midi_pitcher),
            .midi_chord => try s.pushMidiDev(.{ .chord = .{} }, .midi_chord),
            .midi_velocity => try s.pushMidiDev(.{ .velocity = .{} }, .midi_velocity),
            .midi_note_length => try s.pushMidiDev(.{ .note_length = .{} }, .midi_note_length),
            .midi_arpeggiator => try s.pushMidiDev(.{ .arp = .{} }, .midi_arpeggiator),
            .midi_random => try s.pushMidiDev(.{ .random = .{} }, .midi_random),
            .mx_device_midi_effect => try s.pushMidiDev(.{ .mx_ext = .{} }, .mx_device_midi_effect),
            .lom_id => {
                if (parent == .mx_device_midi_effect and s.active_dev_tag == .mx_device_midi_effect) {
                    if (s.active_dev_branch) |bidx| {
                        if (attrInt(attrs, "Value")) |v| {
                            if (v > 0) {
                                s.out.midi_branches.items[bidx].devs.items[s.active_dev_idx].mx_ext.lom_id = @intCast(v);
                            }
                        }
                    }
                }
            },

            .clip_timeable => if (s.in_midi_track) {
                s.in_clip_timeable = true;
            },
            .arranger_automation => if (s.in_clip_timeable) {
                s.in_arranger_auto = true;
            },
            .midi_clip => if (s.in_arranger_auto) {
                s.in_midi_clip = true;
                s.cur_clip = .{};
                s.cur_clip_key = 0;
                s.has_clip_key = false;
            },
            .current_start => if (s.in_midi_clip and parent == .midi_clip) {
                if (attrFloat(attrs, "Value")) |v| s.cur_clip.start_beat = v;
            },
            .current_end => if (s.in_midi_clip and parent == .midi_clip) {
                if (attrFloat(attrs, "Value")) |v| s.cur_clip.end_beat = v;
            },
            .loop_start => if (s.in_midi_clip and parent == .loop) {
                if (attrFloat(attrs, "Value")) |v| s.cur_clip.loop_start = v;
            },
            .key_track => if (s.in_midi_clip) {
                s.clip_keytrack_start = s.cur_clip.notes.items.len;
                s.cur_clip_key = 0;
                s.has_clip_key = false;
            },
            .midi_key => if (s.in_midi_clip and parent == .key_track) {
                if (attrInt(attrs, "Value")) |v| {
                    if (v >= 0 and v <= 127) {
                        s.cur_clip_key = @intCast(v);
                        s.has_clip_key = true;
                    }
                }
            },
            .midi_note_event => if (s.in_midi_clip) {
                const enabled = if (attrStr(attrs, "IsEnabled")) |en| !std.mem.eql(u8, en, "false") else true;
                if (enabled) {
                    const t = attrFloat(attrs, "Time") orelse 0;
                    const dur = attrFloat(attrs, "Duration") orelse 0.25;
                    try s.cur_clip.notes.append(s.a, .{
                        .beat = t,
                        .dur = dur,
                        .midi_key = s.cur_clip_key,
                    });
                }
            },

            .name => {
                if (s.in_sample_file_ref and parent == .file_ref) {
                    if (attrStr(attrs, "Value")) |v| {
                        if (v.len > 0) {
                            var tmp: std.ArrayList(u8) = .empty;
                            try appendUnescaped(s.a, &tmp, v);
                            s.simpler_name = tmp.items;
                        }
                    }
                } else if (s.in_midi_clip and parent == .midi_clip) {
                    if (attrStr(attrs, "Value")) |v| {
                        var tmp: std.ArrayList(u8) = .empty;
                        try appendUnescaped(s.a, &tmp, v);
                        s.cur_clip.name = tmp.items;
                    }
                }
            },
            .target => {
                if (s.in_midi_track and !s.in_return_track and parent == .midi_output_routing) {
                    if (attrStr(attrs, "Value")) |v| {
                        var ch_val: i32 = 0;
                        if (std.mem.lastIndexOfScalar(u8, v, '/')) |slash| {
                            if (std.fmt.parseInt(i32, v[slash + 1 ..], 10)) |ch| {
                                ch_val = ch;
                                if (ch == 2 or ch == 7) {
                                    s.track_light_mode = .pulse; // Ch. 3 (Programmer) / Ch. 8 (User 1)
                                } else if (ch == 1 or ch == 6) {
                                    s.track_light_mode = .flash; // Ch. 2 (Programmer) / Ch. 7 (User 1)
                                }
                            } else |_| {}
                        }
                        if (isLegacyLaunchpadTarget(v, ch_val, s.out.major_version)) {
                            s.track_legacy_rg = true;
                        }
                    }
                }
            },

            .min, .max => {
                if (attrInt(attrs, "Value")) |iv| {
                    const v: u8 = @intCast(std.math.clamp(iv, 0, 127));
                    if (parent == .branch_selector_range) {
                        if (s.inst_depth > 0 and grand == .instrument_branch) {
                            const f = &s.inst_stack[s.inst_depth - 1];
                            if (tag == .min) f.sel_min = v else f.sel_max = v;
                            if (s.inst_depth == 1 and v < types.max_chains and v > s.out.max_chain_seen) s.out.max_chain_seen = v;
                        } else if (s.branch_depth > 0 and grand == .midi_effect_branch) {
                            const b = &s.out.midi_branches.items[s.branch_stack[s.branch_depth - 1]];
                            b.has_sel = true;
                            if (tag == .min) b.sel_min = v else b.sel_max = v;
                            if (v < types.max_chains and v > s.out.max_chain_seen) s.out.max_chain_seen = v;
                        }
                    } else if (parent == .key_range and !s.in_simpler) {
                        if (s.branch_depth > 0) {
                            const b = &s.out.midi_branches.items[s.branch_stack[s.branch_depth - 1]];
                            if (tag == .min) b.key_min = v else b.key_max = v;
                        } else if (s.inst_depth > 0) {
                            const f = &s.inst_stack[s.inst_depth - 1];
                            if (tag == .min) f.key_min = v else f.key_max = v;
                        }
                    }
                }
            },

            .manual => {
                s.handleManual(parent, grand, attrs);
            },
            else => {},
        }

        if (!self_closing) {
            if (s.depth < s.stack.len) {
                s.stack[s.depth] = tag;
                s.depth += 1;
            }
        } else {
            s.finishTag(tag);
        }
    }

    fn onClose(s: *ParserState, name: []const u8) void {
        const tag = tag_map.get(name) orelse .other;
        if (s.depth > 0) s.depth -= 1;
        s.finishTag(tag);
    }

    fn finishTag(s: *ParserState, tag: Tag) void {
        switch (tag) {
            .master_track => s.in_master = false,
            .return_track => s.in_return_track = false,
            .midi_track => {
                if (s.in_midi_track and !s.in_return_track) {
                    if (s.track_has_drum) {
                        // Keep Arrangement MidiClips from the sample track for AutoPlay
                        s.out.arr_clips.appendSlice(s.a, s.track_clips.items) catch {};
                    } else {
                        // Light tracks have MIDI effect racks without DrumGroupDevice
                        for (s.track_root_racks.items) |ridx| {
                            s.out.light_root_racks.append(s.a, .{
                                .rack_idx = ridx,
                                .mode = s.track_light_mode,
                                .legacy_rg = s.track_legacy_rg,
                            }) catch {};
                        }
                    }
                }
                s.in_midi_track = false;
                s.track_has_drum = false;
            },
            .drum_group_device => s.in_drum_group = false,
            .drum_branch => {
                if (s.in_drum_branch) {
                    if (s.has_drum_note and !s.drum_branch_muted) {
                        for (s.out.pad_samples.items[s.drum_branch_sample_start..]) |*pm| {
                            pm.midi_note = s.cur_drum_note;
                        }
                    } else {
                        s.out.pad_samples.items.len = s.drum_branch_sample_start;
                    }
                }
                s.in_drum_branch = false;
                s.drum_branch_muted = false;
                s.has_drum_note = false;
            },
            .instrument_branch => {
                if (s.inst_depth > 0) {
                    s.inst_depth -= 1;
                    const frame = s.inst_stack[s.inst_depth];
                    if (frame.muted) {
                        s.out.pad_samples.items.len = frame.sample_start;
                    } else {
                        for (s.out.pad_samples.items[frame.sample_start..]) |*pm| {
                            // Outermost InstrumentBranch owns page/chain selector; all nesting levels intersect KeyRange.
                            if (s.inst_depth == 0) {
                                pm.sel_min = frame.sel_min;
                                pm.sel_max = frame.sel_max;
                            }
                            pm.key_min = @max(pm.key_min, frame.key_min);
                            pm.key_max = @min(pm.key_max, frame.key_max);
                        }
                    }
                }
            },
            .file_ref => s.in_sample_file_ref = false,
            .sample_ref => {
                s.in_sample_ref = false;
                s.in_sample_file_ref = false;
            },
            .original_simpler, .multi_sampler => {
                if (s.in_simpler and s.simpler_on and s.in_drum_branch and (s.simpler_name.len > 0 or s.simpler_rel.items.len > 0)) {
                    const rel_copy = s.a.dupe(u8, s.simpler_rel.items) catch "";
                    const sel_min: u8 = if (s.inst_depth > 0) s.inst_stack[0].sel_min else 0;
                    const sel_max: u8 = if (s.inst_depth > 0) s.inst_stack[0].sel_max else 0;
                    s.out.pad_samples.append(s.a, .{
                        .midi_note = s.cur_drum_note,
                        .sel_min = sel_min,
                        .sel_max = sel_max,
                        .rel_path = rel_copy,
                        .file_name = s.simpler_name,
                        .loop = s.simpler_loop,
                        .sample_start = s.simpler_start,
                        .sample_end = s.simpler_end,
                        .default_duration = s.simpler_default_dur,
                        .default_sample_rate = s.simpler_default_sr,
                    }) catch {};
                }
                s.in_simpler = false;
            },
            .midi_effect_group_device => {
                if (s.rack_depth > 0) s.rack_depth -= 1;
                if (s.active_dev_tag == .midi_effect_group_device) s.active_dev_tag = .other;
            },
            .midi_effect_branch => {
                if (s.branch_depth > 0) s.branch_depth -= 1;
            },
            .midi_pitcher, .midi_chord, .midi_velocity, .midi_note_length, .midi_arpeggiator, .midi_random, .mx_device_midi_effect => {
                if (s.active_dev_tag == tag) {
                    s.active_dev_branch = null;
                    s.active_dev_tag = .other;
                }
            },
            .key_track => {
                if (s.in_midi_clip) {
                    if (s.has_clip_key) {
                        for (s.cur_clip.notes.items[s.clip_keytrack_start..]) |*n| {
                            n.midi_key = s.cur_clip_key;
                        }
                    } else {
                        s.cur_clip.notes.items.len = s.clip_keytrack_start;
                    }
                    s.has_clip_key = false;
                }
            },
            .clip_timeable => s.in_clip_timeable = false,
            .arranger_automation => s.in_arranger_auto = false,
            .midi_clip => {
                if (s.in_midi_clip and s.cur_clip.notes.items.len > 0) {
                    s.track_clips.append(s.a, s.cur_clip) catch {};
                }
                s.in_midi_clip = false;
            },
            else => {},
        }
    }

    fn pushMidiDev(s: *ParserState, dev: MidiDev, tag: Tag) !void {
        if (s.branch_depth == 0) return;
        const bidx = s.branch_stack[s.branch_depth - 1];
        const b = &s.out.midi_branches.items[bidx];
        s.active_dev_branch = bidx;
        s.active_dev_idx = b.devs.items.len;
        s.active_dev_tag = tag;
        try b.devs.append(s.a, dev);
    }

    fn handleManual(s: *ParserState, parent: Tag, grand: Tag, attrs: []const u8) void {
        if (parent == .tempo and s.in_master) {
            if (attrFloat(attrs, "Value")) |v| {
                if (v >= 20.0 and v <= 400.0) s.out.tempo = v;
            }
            return;
        }
        if (parent == .speaker and grand == .mixer_device) {
            if (attrStr(attrs, "Value")) |v| {
                const is_muted = std.mem.eql(u8, v, "false");
                if (s.branch_depth > 0) {
                    s.out.midi_branches.items[s.branch_stack[s.branch_depth - 1]].muted = is_muted;
                } else if (s.inst_depth > 0) {
                    s.inst_stack[s.inst_depth - 1].muted = is_muted;
                } else if (s.in_drum_branch) {
                    s.drum_branch_muted = is_muted;
                }
            }
            return;
        }
        if (parent == .on) {
            const on_val = if (attrStr(attrs, "Value")) |v| !std.mem.eql(u8, v, "false") else true;
            if (s.in_simpler and (grand == .original_simpler or grand == .multi_sampler)) {
                s.simpler_on = on_val;
                return;
            }
            if (grand == .midi_effect_group_device and s.rack_depth > 0) {
                s.out.midi_racks.items[s.rack_stack[s.rack_depth - 1]].on = on_val;
                return;
            }
            if (s.active_dev_branch) |bidx| {
                const dev = &s.out.midi_branches.items[bidx].devs.items[s.active_dev_idx];
                switch (dev.*) {
                    .pitcher => |*p| p.on = on_val,
                    .chord => |*ch| ch.on = on_val,
                    .velocity => |*ve| ve.on = on_val,
                    .note_length => |*nl| nl.on = on_val,
                    .arp => |*ar| ar.on = on_val,
                    .random => |*rnd| rnd.on = on_val,
                    .rack => |*rk| rk.on = on_val,
                    .mx_ext => |*mx| if (grand == .mx_device_midi_effect) {
                        mx.on = on_val;
                    },
                }
            }
            return;
        }

        const bidx = s.active_dev_branch orelse return;
        const dev = &s.out.midi_branches.items[bidx].devs.items[s.active_dev_idx];
        switch (dev.*) {
            .pitcher => |*p| switch (parent) {
                .pitch => if (attrInt(attrs, "Value")) |v| {
                    p.pitch = @intCast(std.math.clamp(v, -128, 128));
                },
                .lowest => if (attrInt(attrs, "Value")) |v| {
                    p.lowest = @intCast(std.math.clamp(v, 0, 127));
                },
                .range => if (attrInt(attrs, "Value")) |v| {
                    p.range = @intCast(std.math.clamp(v, 0, 127));
                },
                else => {},
            },
            .chord => |*ch| switch (parent) {
                .shift1, .shift2, .shift3, .shift4, .shift5, .shift6 => {
                    const idx = @intFromEnum(parent) - @intFromEnum(Tag.shift1);
                    if (attrInt(attrs, "Value")) |v| ch.shifts[idx] = @intCast(std.math.clamp(v, -64, 64));
                },
                .velocity1, .velocity2, .velocity3, .velocity4, .velocity5, .velocity6 => {
                    const idx = @intFromEnum(parent) - @intFromEnum(Tag.velocity1);
                    if (attrFloat(attrs, "Value")) |v| ch.vels[idx] = @floatCast(v);
                },
                else => {},
            },
            .velocity => |*ve| switch (parent) {
                .mode => if (attrInt(attrs, "Value")) |v| {
                    ve.mode = @intCast(std.math.clamp(v, 0, 2));
                },
                .operation => if (attrInt(attrs, "Value")) |v| {
                    ve.operation = @intCast(std.math.clamp(v, 0, 3));
                },
                .min_out => if (attrInt(attrs, "Value")) |v| {
                    ve.min_out = @intCast(std.math.clamp(v, 0, 127));
                },
                .max_out => if (attrInt(attrs, "Value")) |v| {
                    ve.max_out = @intCast(std.math.clamp(v, 0, 127));
                },
                .lowest => if (attrInt(attrs, "Value")) |v| {
                    ve.lowest = @intCast(std.math.clamp(v, 0, 127));
                },
                .range => if (attrInt(attrs, "Value")) |v| {
                    ve.range = @intCast(std.math.clamp(v, 0, 127));
                },
                else => {},
            },
            .note_length => |*nl| switch (parent) {
                .mode => if (attrStr(attrs, "Value")) |v| {
                    nl.trigger_off = std.mem.eql(u8, v, "true");
                },
                .sync_state => if (attrStr(attrs, "Value")) |v| {
                    nl.sync_state = std.mem.eql(u8, v, "true");
                },
                .synced_length => if (attrInt(attrs, "Value")) |v| {
                    nl.synced_len = @intCast(std.math.clamp(v, 0, 15));
                },
                .time_length => if (attrFloat(attrs, "Value")) |v| {
                    nl.time_ms = @floatCast(std.math.clamp(v, 1.0, 60000.0));
                },
                .gate => if (attrFloat(attrs, "Value")) |v| {
                    nl.gate = @floatCast(std.math.clamp(v, 1.0, 200.0));
                },
                else => {},
            },
            .arp => |*ar| switch (parent) {
                .mode => if (attrInt(attrs, "Value")) |v| {
                    ar.mode = @intCast(std.math.clamp(v, 0, 20));
                },
                .sync_state => if (attrStr(attrs, "Value")) |v| {
                    ar.sync_state = std.mem.eql(u8, v, "true");
                },
                .synced_rate => if (attrInt(attrs, "Value")) |v| {
                    ar.synced_rate = @intCast(std.math.clamp(v, 0, 15));
                },
                .free_rate => if (attrFloat(attrs, "Value")) |v| {
                    ar.free_rate_ms = @floatCast(std.math.clamp(v, 1.0, 10000.0));
                },
                .repeat_count => if (attrInt(attrs, "Value")) |v| {
                    ar.repeat_count = @intCast(std.math.clamp(v, 0, 16));
                },
                .gate => if (attrFloat(attrs, "Value")) |v| {
                    ar.gate = @floatCast(std.math.clamp(v, 1.0, 200.0));
                },
                .transpose_steps => if (attrInt(attrs, "Value")) |v| {
                    ar.transpose_steps = @intCast(std.math.clamp(v, 0, 8));
                },
                .transpose_distance => if (attrInt(attrs, "Value")) |v| {
                    ar.transpose_dist = @intCast(std.math.clamp(v, -48, 48));
                },
                else => {},
            },
            .random => |*rnd| switch (parent) {
                .chance => if (attrFloat(attrs, "Value")) |v| {
                    rnd.chance = @floatCast(std.math.clamp(v, 0.0, 1.0));
                },
                .choices => if (attrInt(attrs, "Value")) |v| {
                    rnd.choices = @intCast(std.math.clamp(v, 1, 24));
                },
                .scale => if (attrInt(attrs, "Value")) |v| {
                    rnd.scale = @intCast(std.math.clamp(v, 1, 24));
                },
                .sign => if (attrInt(attrs, "Value")) |v| {
                    rnd.sign = @intCast(std.math.clamp(v, 0, 2));
                },
                .alternate => if (attrStr(attrs, "Value")) |v| {
                    rnd.alternate = std.mem.eql(u8, v, "true");
                },
                else => {},
            },
            .rack, .mx_ext => {},
        }
    }
};

fn parseAlsGzipStream(a: std.mem.Allocator, als_bytes: []const u8, out: *ParsedAls) !void {
    var st: ParserState = .{ .a = a, .out = out };
    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(a);

    if (als_bytes.len >= 2 and als_bytes[0] == 0x1f and als_bytes[1] == 0x8b) {
        var in_reader: std.Io.Reader = .fixed(als_bytes);
        const window_buf = try a.alloc(u8, std.compress.flate.max_window_len);
        defer a.free(window_buf);
        var decomp = std.compress.flate.Decompress.init(&in_reader, .gzip, window_buf);
        var chunk: [32768]u8 = undefined;
        while (true) {
            const n = decomp.reader.readSliceShort(&chunk) catch return error.AlsDecompressFailed;
            if (n == 0) break;
            try feedXmlChunk(a, &st, &carry, chunk[0..n]);
        }
    } else {
        try feedXmlChunk(a, &st, &carry, als_bytes);
    }
}

fn feedXmlChunk(a: std.mem.Allocator, st: *ParserState, carry: *std.ArrayList(u8), chunk: []const u8) !void {
    var data = chunk;
    if (carry.items.len > 0) {
        try carry.appendSlice(a, chunk);
        data = carry.items;
    }

    var pos: usize = 0;
    while (pos < data.len) {
        const lt = std.mem.indexOfScalarPos(u8, data, pos, '<') orelse {
            pos = data.len;
            break;
        };
        const gt = std.mem.indexOfScalarPos(u8, data, lt + 1, '>') orelse {
            // Incomplete tag split across chunks: keep from `lt` in carry.
            const tail = data[lt..];
            if (carry.items.len > 0) {
                std.mem.copyForwards(u8, carry.items[0..tail.len], tail);
                carry.items.len = tail.len;
            } else {
                try carry.appendSlice(a, tail);
            }
            return;
        };
        const inner = data[lt + 1 .. gt];
        pos = gt + 1;
        if (inner.len == 0 or inner[0] == '?' or inner[0] == '!') continue;

        if (inner[0] == '/') {
            const name = std.mem.trim(u8, inner[1..], " \t\r\n");
            st.onClose(name);
        } else {
            const self_closing = inner[inner.len - 1] == '/';
            const body = if (self_closing) inner[0 .. inner.len - 1] else inner;
            const sp = std.mem.indexOfAny(u8, body, " \t\r\n");
            const name = if (sp) |idx| body[0..idx] else body;
            const attrs = if (sp) |idx| body[idx + 1 ..] else "";
            try st.onOpen(name, attrs, self_closing);
        }
    }
    carry.clearRetainingCapacity();
}

fn attrStr(attrs: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < attrs.len) {
        const found = std.mem.indexOfPos(u8, attrs, pos, key) orelse return null;
        // Ensure match is at attribute boundary
        if (found > 0 and attrs[found - 1] != ' ' and attrs[found - 1] != '\t' and attrs[found - 1] != '\n' and attrs[found - 1] != '\r') {
            pos = found + key.len;
            continue;
        }
        const after = found + key.len;
        if (after + 2 <= attrs.len and attrs[after] == '=' and (attrs[after + 1] == '"' or attrs[after + 1] == '\'')) {
            const quote = attrs[after + 1];
            const val_start = after + 2;
            const val_end = std.mem.indexOfScalarPos(u8, attrs, val_start, quote) orelse return null;
            return attrs[val_start..val_end];
        }
        pos = after;
    }
    return null;
}

fn attrInt(attrs: []const u8, key: []const u8) ?i32 {
    const s = attrStr(attrs, key) orelse return null;
    if (std.fmt.parseInt(i32, s, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, s) catch return null;
    return @intFromFloat(@round(f));
}

fn attrFloat(attrs: []const u8, key: []const u8) ?f64 {
    const s = attrStr(attrs, key) orelse return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn attrU64(attrs: []const u8, key: []const u8) ?u64 {
    const s = attrStr(attrs, key) orelse return null;
    if (std.fmt.parseInt(u64, s, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(f) or f < 0.0) return null;
    return @intFromFloat(@round(f));
}

fn appendUnescaped(a: std.mem.Allocator, dst: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try dst.append(a, '&');
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try dst.append(a, '<');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try dst.append(a, '>');
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try dst.append(a, '"');
                i += 6;
                continue;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try dst.append(a, '\'');
                i += 6;
                continue;
            }
        }
        try dst.append(a, s[i]);
        i += 1;
    }
}

// ============================================================================
// MIDI Effect Rack Lightshow Simulator
// ============================================================================

const SimNote = struct {
    start_ms: f64,
    dur_ms: f64,
    note: u8,
    vel: u8,
};

const LedTransKind = enum(u8) { off = 0, on = 1, update = 2 };

const LedTrans = struct {
    t_ms: u32,
    kind: LedTransKind,
    /// 0..63 = 8x8 pad (row*8 + col), 64..95 = ring mc 1..32, 96 = logo (idx 32)
    slot: u8,
    vel: u8,
    color: u32,
};

fn scaleArgb(argb: u32, factor: f64) u32 {
    const a_ch: u32 = argb & 0xFF000000;
    const r: u32 = @intFromFloat(std.math.clamp(@round(@as(f64, @floatFromInt((argb >> 16) & 0xFF)) * factor), 0.0, 255.0));
    const g: u32 = @intFromFloat(std.math.clamp(@round(@as(f64, @floatFromInt((argb >> 8) & 0xFF)) * factor), 0.0, 255.0));
    const b: u32 = @intFromFloat(std.math.clamp(@round(@as(f64, @floatFromInt(argb & 0xFF)) * factor), 0.0, 255.0));
    return a_ch | (r << 16) | (g << 8) | b;
}

const max_sim_notes = 32768;
const max_sim_depth = 12;

const MidiExtEntry = struct {
    file_path: []const u8 = "",
    temp1: f64 = 120.0,
    temp2: f64 = 120.0,
};

const MidiExtCtx = struct {
    entries: std.AutoHashMapUnmanaged(u32, MidiExtEntry) = .empty,
    mid_path_index: std.StringHashMapUnmanaged(VirtualFile) = .empty,
    mid_base_index: std.StringHashMapUnmanaged(VirtualFile) = .empty,
    cache: std.AutoHashMapUnmanaged(u32, []const SimNote) = .empty,
};

fn buildMidiExtCtx(a: std.mem.Allocator, files: []const VirtualFile) !MidiExtCtx {
    var ctx: MidiExtCtx = .{};
    for (files) |f| {
        if (endsWithIgnoreCase(f.rel_path, ".mid") or endsWithIgnoreCase(f.rel_path, ".midi")) {
            const low_full = try lowerAlloc(a, f.rel_path);
            try ctx.mid_path_index.put(a, low_full, f);
            const low_base = try lowerAlloc(a, basenameOf(f.rel_path));
            if (!ctx.mid_base_index.contains(low_base)) try ctx.mid_base_index.put(a, low_base, f);
        }
        if (std.ascii.eqlIgnoreCase(basenameOf(f.rel_path), "0save")) {
            try parseZeroSave(a, f.bytes, &ctx);
        }
    }
    return ctx;
}

fn parseZeroSave(a: std.mem.Allocator, bytes: []const u8, ctx: *MidiExtCtx) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len < 6) continue;
        const comma = std.mem.indexOfScalar(u8, line, ',') orelse continue;
        const key = std.mem.trim(u8, line[0..comma], " \t\"");
        if (!std.mem.startsWith(u8, key, "id")) continue;

        var d_end: usize = 2;
        while (d_end < key.len and std.ascii.isDigit(key[d_end])) : (d_end += 1) {}
        if (d_end == 2) continue;
        const lom_id = std.fmt.parseInt(u32, key[2..d_end], 10) catch continue;
        const prop = key[d_end..];

        var rhs = std.mem.trim(u8, line[comma + 1 ..], " \t");
        if (std.mem.endsWith(u8, rhs, ";")) rhs = std.mem.trimEnd(u8, rhs[0 .. rhs.len - 1], " \t");
        // Max coll format repeats the key before the value: "id13midifile, id13midifile ./MIDIext/..."
        if (std.mem.startsWith(u8, rhs, key)) {
            rhs = std.mem.trimStart(u8, rhs[key.len..], " \t");
        }
        if (rhs.len >= 2 and rhs[0] == '"' and rhs[rhs.len - 1] == '"') {
            rhs = rhs[1 .. rhs.len - 1];
        }
        if (rhs.len == 0) continue;

        const gop = try ctx.entries.getOrPut(a, lom_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (std.mem.eql(u8, prop, "midifile")) {
            gop.value_ptr.file_path = rhs;
        } else if (std.mem.eql(u8, prop, "temp1")) {
            if (std.fmt.parseFloat(f64, rhs)) |v| {
                if (v > 0) gop.value_ptr.temp1 = v;
            } else |_| {}
        } else if (std.mem.eql(u8, prop, "temp2")) {
            if (std.fmt.parseFloat(f64, rhs)) |v| {
                if (v > 0) gop.value_ptr.temp2 = v;
            } else |_| {}
        }
    }
}

fn resolveMidiExtNotes(a: std.mem.Allocator, ctx: *MidiExtCtx, lom_id: u32) std.mem.Allocator.Error!?[]const SimNote {
    if (lom_id == 0) return null;
    if (ctx.cache.get(lom_id)) |cached| return cached;
    const entry = ctx.entries.get(lom_id) orelse return null;
    if (entry.file_path.len == 0) return null;

    var norm: std.ArrayList(u8) = .empty;
    defer norm.deinit(a);
    for (entry.file_path) |ch| {
        try norm.append(a, if (ch == '\\') '/' else std.ascii.toLower(ch));
    }
    var trimmed: []const u8 = norm.items;
    while (std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "/")) {
        trimmed = trimmed[if (trimmed[0] == '.') 2 else 1 ..];
    }

    var vf: ?VirtualFile = ctx.mid_path_index.get(trimmed);
    if (vf == null) {
        var it = ctx.mid_path_index.iterator();
        while (it.next()) |kv| {
            if (std.mem.endsWith(u8, kv.key_ptr.*, trimmed)) {
                vf = kv.value_ptr.*;
                break;
            }
        }
    }
    if (vf == null) {
        const base = basenameOf(trimmed);
        vf = ctx.mid_base_index.get(base);
    }

    const notes: []const SimNote = if (vf) |f|
        try parseSmfNotes(a, f.bytes, entry.temp1, entry.temp2)
    else
        &.{};
    try ctx.cache.put(a, lom_id, notes);
    return notes;
}

fn readVlq(data: []const u8, pos: *usize, end: usize) ?u32 {
    var val: u32 = 0;
    var count: u8 = 0;
    while (pos.* < end and count < 4) : (count += 1) {
        const b = data[pos.*];
        pos.* += 1;
        val = (val << 7) | (b & 0x7F);
        if ((b & 0x80) == 0) return val;
    }
    return null;
}

fn parseSmfNotes(a: std.mem.Allocator, data: []const u8, temp1: f64, temp2: f64) std.mem.Allocator.Error![]const SimNote {
    if (data.len < 14 or !std.mem.eql(u8, data[0..4], "MThd")) return &.{};
    const hdr_len = std.mem.readInt(u32, data[4..8], .big);
    if (hdr_len < 6 or 8 + hdr_len > data.len) return &.{};
    const division = std.mem.readInt(u16, data[12..14], .big);
    const is_smpte = (division & 0x8000) != 0;
    const tpqn: f64 = if (!is_smpte) @floatFromInt(@max(division, 1)) else 480.0;
    const smpte_tps: f64 = if (is_smpte) blk: {
        const fps_i8: i8 = @bitCast(@as(u8, @intCast(division >> 8)));
        const fps: f64 = @floatFromInt(@max(-@as(i32, fps_i8), 1));
        const sub: f64 = @floatFromInt(@max(division & 0xFF, 1));
        break :blk fps * sub;
    } else 0.0;

    const TempoEvt = struct { tick: u64, us_per_q: f64 };
    const RawEvt = struct { tick: u64, seq: u32, note: u8, vel: u8, is_on: bool };

    var tempos: std.ArrayList(TempoEvt) = .empty;
    defer tempos.deinit(a);
    var raws: std.ArrayList(RawEvt) = .empty;
    defer raws.deinit(a);

    var seq_ctr: u32 = 0;
    var pos: usize = 8 + hdr_len;
    while (pos + 8 <= data.len) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        pos += 8;
        const trk_end = @min(pos + chunk_len, data.len);
        if (!std.mem.eql(u8, chunk_id, "MTrk")) {
            pos = trk_end;
            continue;
        }

        var p = pos;
        var tick: u64 = 0;
        var running_status: u8 = 0;
        while (p < trk_end) {
            const delta = readVlq(data, &p, trk_end) orelse break;
            tick += delta;
            if (p >= trk_end) break;

            var status = data[p];
            if (status >= 0x80) {
                p += 1;
                if (status < 0xF0) running_status = status;
            } else {
                if (running_status == 0) break;
                status = running_status;
            }

            if (status == 0xFF) {
                if (p >= trk_end) break;
                const meta_type = data[p];
                p += 1;
                const mlen = readVlq(data, &p, trk_end) orelse break;
                if (meta_type == 0x51 and mlen == 3 and p + 3 <= trk_end) {
                    const us: u32 = (@as(u32, data[p]) << 16) | (@as(u32, data[p + 1]) << 8) | data[p + 2];
                    if (us > 0) try tempos.append(a, .{ .tick = tick, .us_per_q = @floatFromInt(us) });
                }
                p = @min(p + mlen, trk_end);
                if (meta_type == 0x2F) break;
            } else if (status == 0xF0 or status == 0xF7) {
                const slen = readVlq(data, &p, trk_end) orelse break;
                p = @min(p + slen, trk_end);
            } else {
                const hi = status & 0xF0;
                if (hi == 0xC0 or hi == 0xD0) {
                    if (p + 1 > trk_end) break;
                    p += 1;
                } else {
                    if (p + 2 > trk_end) break;
                    const d1 = data[p] & 0x7F;
                    const d2 = data[p + 1] & 0x7F;
                    p += 2;
                    if (hi == 0x90 and d2 > 0) {
                        try raws.append(a, .{ .tick = tick, .seq = seq_ctr, .note = d1, .vel = d2, .is_on = true });
                        seq_ctr += 1;
                    } else if (hi == 0x80 or (hi == 0x90 and d2 == 0)) {
                        try raws.append(a, .{ .tick = tick, .seq = seq_ctr, .note = d1, .vel = 0, .is_on = false });
                        seq_ctr += 1;
                    }
                }
            }
        }
        pos = trk_end;
    }

    if (raws.items.len == 0) return &.{};

    std.mem.sort(TempoEvt, tempos.items, {}, struct {
        fn lt(_: void, x: TempoEvt, y: TempoEvt) bool {
            return x.tick < y.tick;
        }
    }.lt);
    std.mem.sort(RawEvt, raws.items, {}, struct {
        fn lt(_: void, x: RawEvt, y: RawEvt) bool {
            if (x.tick != y.tick) return x.tick < y.tick;
            if (x.is_on != y.is_on) return !x.is_on;
            return x.seq < y.seq;
        }
    }.lt);

    const tempo_scale: f64 = if (temp1 > 0 and temp2 > 0) temp1 / temp2 else 1.0;
    const init_us: f64 = 60_000_000.0 / (if (temp1 > 0) temp1 else 120.0);

    var cur_tick: u64 = 0;
    var cur_ms: f64 = 0.0;
    var cur_us: f64 = init_us;
    var ti: usize = 0;

    var active_on: [128]bool = @splat(false);
    var active_start: [128]f64 = @splat(0.0);
    var active_vel: [128]u8 = @splat(0);

    var notes: std.ArrayList(SimNote) = .empty;
    for (raws.items) |ev| {
        if (is_smpte) {
            cur_ms = (@as(f64, @floatFromInt(ev.tick)) / smpte_tps) * 1000.0 * tempo_scale;
        } else {
            while (ti < tempos.items.len and tempos.items[ti].tick <= ev.tick) : (ti += 1) {
                const dt = tempos.items[ti].tick - cur_tick;
                cur_ms += (@as(f64, @floatFromInt(dt)) / tpqn) * (cur_us / 1000.0) * tempo_scale;
                cur_tick = tempos.items[ti].tick;
                cur_us = tempos.items[ti].us_per_q;
            }
            const dt = ev.tick - cur_tick;
            cur_ms += (@as(f64, @floatFromInt(dt)) / tpqn) * (cur_us / 1000.0) * tempo_scale;
            cur_tick = ev.tick;
        }

        if (ev.is_on) {
            if (active_on[ev.note] and notes.items.len < max_sim_notes) {
                try notes.append(a, .{
                    .start_ms = active_start[ev.note],
                    .dur_ms = @max(cur_ms - active_start[ev.note], 10.0),
                    .note = ev.note,
                    .vel = active_vel[ev.note],
                });
            }
            active_on[ev.note] = true;
            active_start[ev.note] = cur_ms;
            active_vel[ev.note] = ev.vel;
        } else if (active_on[ev.note]) {
            if (notes.items.len < max_sim_notes) {
                try notes.append(a, .{
                    .start_ms = active_start[ev.note],
                    .dur_ms = @max(cur_ms - active_start[ev.note], 10.0),
                    .note = ev.note,
                    .vel = active_vel[ev.note],
                });
            }
            active_on[ev.note] = false;
        }
    }
    for (0..128) |n| {
        if (active_on[n] and notes.items.len < max_sim_notes) {
            try notes.append(a, .{
                .start_ms = active_start[n],
                .dur_ms = 120.0,
                .note = @intCast(n),
                .vel = active_vel[n],
            });
        }
    }
    return notes.items;
}

fn lcmUsize(x: usize, y: usize) usize {
    if (x == 0 or y == 0) return @max(x, y);
    return (x / std.math.gcd(x, y)) * y;
}

fn simulatePadLights(
    a: std.mem.Allocator,
    parsed: *const ParsedAls,
    midiext: *MidiExtCtx,
    layout: NoteLayout,
    beat_ms: f64,
    chain: u8,
    trig_note: u8,
) ![]const []const LedEvent {
    var cycle_len: usize = 1;
    const evs0 = try simulatePadLightsPress(a, parsed, midiext, layout, beat_ms, chain, trig_note, 0, &cycle_len);
    if (cycle_len <= 1) {
        if (evs0.len == 0) return &.{};
        const single = try a.alloc([]const LedEvent, 1);
        single[0] = evs0;
        return single;
    }

    const anims = try a.alloc([]const LedEvent, cycle_len);
    anims[0] = evs0;
    var any_non_empty = evs0.len > 0;
    for (1..cycle_len) |p| {
        var dummy: usize = cycle_len;
        anims[p] = try simulatePadLightsPress(a, parsed, midiext, layout, beat_ms, chain, trig_note, p, &dummy);
        if (anims[p].len > 0) any_non_empty = true;
    }
    if (!any_non_empty) return &.{};
    return anims;
}

fn simulatePadLightsPress(
    a: std.mem.Allocator,
    parsed: *const ParsedAls,
    midiext: *MidiExtCtx,
    layout: NoteLayout,
    beat_ms: f64,
    chain: u8,
    trig_note: u8,
    press_idx: usize,
    cycle_len: *usize,
) ![]const LedEvent {
    var out_notes: std.ArrayList(SimNote) = .empty;
    defer out_notes.deinit(a);

    var trans: std.ArrayList(LedTrans) = .empty;
    defer trans.deinit(a);

    const seed = [_]SimNote{.{
        .start_ms = 0,
        .dur_ms = 120.0,
        .note = trig_note,
        .vel = 127,
    }};

    for (parsed.light_root_racks.items) |root_rack| {
        out_notes.clearRetainingCapacity();
        try evalRack(a, parsed, midiext, root_rack.rack_idx, beat_ms, chain, &seed, &out_notes, 0, press_idx, cycle_len);
        for (out_notes.items) |sn| {
            if (sn.vel == 0) continue;
            const vel: u8 = if (root_rack.legacy_rg) launchpadSToRgbVelocity(sn.vel) else sn.vel;
            if (vel == 0) continue;
            const slot: u8 = if (midiNoteToXY(layout, sn.note)) |xy|
                xy[0] * 8 + xy[1]
            else if (midiNoteToRing(layout, sn.note)) |ridx|
                64 + ridx
            else
                continue;
            const t_on: u32 = @intFromFloat(std.math.clamp(@round(sn.start_ms), 0.0, 300000.0));
            const dur_clamped = std.math.clamp(sn.dur_ms, 5.0, 60000.0);
            const t_off: u32 = @intFromFloat(std.math.clamp(@round(sn.start_ms + dur_clamped), @as(f64, @floatFromInt(t_on + 1)), 360000.0));
            const base_col = palette.argbOf(vel);

            if (root_rack.mode == .pulse and dur_clamped >= 300.0) {
                // Launchpad hardware pulsing: smooth breathing cycle over 2 beats (20%..100% brightness).
                const period_ms = @max(beat_ms * 2.0, 400.0);
                const step_ms = @max(period_ms / 16.0, @max(65.0, dur_clamped / 240.0));
                try trans.append(a, .{ .t_ms = t_on, .kind = .on, .slot = slot, .vel = vel, .color = base_col });
                var dt: f64 = step_ms;
                while (dt + 15.0 < dur_clamped) : (dt += step_ms) {
                    const phase = (dt / period_ms) * (2.0 * std.math.pi);
                    const k = 0.20 + 0.80 * 0.5 * (1.0 + @cos(phase));
                    const col = scaleArgb(base_col, k);
                    const v = palette.nearestVelocity(col);
                    const t_cur: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(t_on)) + dt));
                    if (t_cur > t_on and t_cur < t_off) {
                        try trans.append(a, .{ .t_ms = t_cur, .kind = .update, .slot = slot, .vel = v, .color = col });
                    }
                }
                try trans.append(a, .{ .t_ms = t_off, .kind = .off, .slot = slot, .vel = 0, .color = 0 });
            } else if (root_rack.mode == .flash and dur_clamped >= 200.0) {
                const half = @max(beat_ms * 0.5, 100.0);
                var dt: f64 = 0.0;
                while (dt < dur_clamped) : (dt += half * 2.0) {
                    const s_t: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(t_on)) + dt));
                    const e_t: u32 = @min(t_off, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t_on)) + dt + half))));
                    if (e_t > s_t) {
                        try trans.append(a, .{ .t_ms = s_t, .kind = .on, .slot = slot, .vel = vel, .color = base_col });
                        try trans.append(a, .{ .t_ms = e_t, .kind = .off, .slot = slot, .vel = 0, .color = 0 });
                    }
                }
            } else {
                try trans.append(a, .{ .t_ms = t_on, .kind = .on, .slot = slot, .vel = vel, .color = base_col });
                try trans.append(a, .{ .t_ms = t_off, .kind = .off, .slot = slot, .vel = 0, .color = 0 });
            }
        }
    }
    if (trans.items.len == 0) return &.{};

    std.mem.sort(LedTrans, trans.items, {}, struct {
        fn lessThan(_: void, x: LedTrans, y: LedTrans) bool {
            if (x.t_ms != y.t_ms) return x.t_ms < y.t_ms;
            // Process OFF before ON before UPDATE at identical timestamp so re-triggered pads/ring stay lit.
            if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
            return x.slot < y.slot;
        }
    }.lessThan);

    var events: std.ArrayList(LedEvent) = .empty;
    const total_slots = 64 + types.logo_led_index + 1;
    var active: [total_slots]u16 = @splat(0);
    var last_on_t: [total_slots]u32 = @splat(std.math.maxInt(u32));
    var last_on_col: [total_slots]u32 = @splat(0);
    var last_on_vel: [total_slots]u8 = @splat(0);
    var cur_t: u32 = 0;

    for (trans.items) |tr| {
        const cell: usize = tr.slot;
        switch (tr.kind) {
            .on, .update => {
                if (tr.kind == .update and active[cell] == 0) continue;
                const already_same = (tr.kind == .on and active[cell] > 0 and last_on_t[cell] == tr.t_ms and last_on_vel[cell] == tr.vel and last_on_col[cell] == tr.color);
                if (tr.kind == .on) active[cell] +|= 1;
                if (already_same) continue;
                if (tr.t_ms > cur_t) {
                    try events.append(a, .{ .delay = tr.t_ms - cur_t });
                    cur_t = tr.t_ms;
                }
                last_on_t[cell] = tr.t_ms;
                last_on_col[cell] = tr.color;
                last_on_vel[cell] = tr.vel;
                if (tr.slot < 64) {
                    try events.append(a, .{ .pad_on = .{
                        .row = tr.slot / 8,
                        .col = tr.slot % 8,
                        .color = tr.color,
                        .velocity = tr.vel,
                    } });
                } else {
                    try events.append(a, .{ .ring_on = .{
                        .idx = tr.slot - 64,
                        .color = tr.color,
                        .velocity = tr.vel,
                    } });
                }
            },
            .off => {
                if (active[cell] > 0) active[cell] -= 1;
                if (active[cell] == 0) {
                    last_on_t[cell] = std.math.maxInt(u32);
                    if (tr.t_ms > cur_t) {
                        try events.append(a, .{ .delay = tr.t_ms - cur_t });
                        cur_t = tr.t_ms;
                    }
                    if (tr.slot < 64) {
                        try events.append(a, .{ .pad_off = .{ .row = tr.slot / 8, .col = tr.slot % 8 } });
                    } else {
                        try events.append(a, .{ .ring_off = tr.slot - 64 });
                    }
                }
            },
        }
    }
    return events.items;
}

fn branchChildRackMatchesNote(parsed: *const ParsedAls, b: *const MidiBranch, note: u8) bool {
    for (b.devs.items) |dev| {
        if (dev != .rack or !dev.rack.on) continue;
        const child_rack = &parsed.midi_racks.items[dev.rack.rack_idx];
        if (!child_rack.on) continue;
        for (child_rack.branches.items) |cbidx| {
            const cb = &parsed.midi_branches.items[cbidx];
            if (cb.muted) continue;
            if (cb.key_min == 0 and cb.key_max == 127) continue;
            if (note >= cb.key_min and note <= cb.key_max) return true;
        }
    }
    return false;
}

fn evalRack(
    a: std.mem.Allocator,
    parsed: *const ParsedAls,
    midiext: *MidiExtCtx,
    ridx: u32,
    beat_ms: f64,
    chain: u8,
    in_notes: []const SimNote,
    out_notes: *std.ArrayList(SimNote),
    depth: u8,
    press_idx: usize,
    cycle_len: *usize,
) std.mem.Allocator.Error!void {
    if (depth >= max_sim_depth or in_notes.len == 0 or out_notes.items.len >= max_sim_notes) return;
    const rack = &parsed.midi_racks.items[ridx];
    if (!rack.on) {
        // Bypassed rack passes notes straight through
        const rem = max_sim_notes - out_notes.items.len;
        try out_notes.appendSlice(a, in_notes[0..@min(in_notes.len, rem)]);
        return;
    }

    var filtered: std.ArrayList(SimNote) = .empty;
    defer filtered.deinit(a);

    for (rack.branches.items) |bidx| {
        if (out_notes.items.len >= max_sim_notes) break;
        const b = &parsed.midi_branches.items[bidx];
        if (b.muted) continue;
        // Top-level rack filters by page/chain; nested racks default to sel 0..0 (always active when !has_sel or depth > 0).
        if (depth == 0 and b.has_sel and (chain < b.sel_min or chain > b.sel_max)) continue;

        filtered.clearRetainingCapacity();
        for (in_notes) |sn| {
            if (sn.note >= b.key_min and sn.note <= b.key_max) {
                try filtered.append(a, sn);
            }
        }
        // Rescue 1-branch nested wrapper racks whose stale KeyRange mismatches an inner rack explicitly keyed to the note.
        if (filtered.items.len == 0 and depth > 0 and rack.branches.items.len == 1) {
            for (in_notes) |sn| {
                if (branchChildRackMatchesNote(parsed, b, sn.note)) {
                    try filtered.append(a, sn);
                }
            }
        }
        if (filtered.items.len == 0) continue;

        try evalDeviceChain(a, parsed, midiext, b.devs.items, beat_ms, chain, filtered.items, out_notes, depth + 1, press_idx, cycle_len);
    }
}

fn evalDeviceChain(
    a: std.mem.Allocator,
    parsed: *const ParsedAls,
    midiext: *MidiExtCtx,
    devs: []const MidiDev,
    beat_ms: f64,
    chain: u8,
    in_notes: []const SimNote,
    out_notes: *std.ArrayList(SimNote),
    depth: u8,
    press_idx: usize,
    cycle_len: *usize,
) std.mem.Allocator.Error!void {
    var cur: std.ArrayList(SimNote) = .empty;
    defer cur.deinit(a);
    try cur.appendSlice(a, in_notes);

    var next: std.ArrayList(SimNote) = .empty;
    defer next.deinit(a);

    for (devs) |dev| {
        if (cur.items.len == 0) return;
        next.clearRetainingCapacity();

        switch (dev) {
            .rack => |rk| {
                if (!rk.on) continue;
                try evalRack(a, parsed, midiext, rk.rack_idx, beat_ms, chain, cur.items, &next, depth, press_idx, cycle_len);
            },
            .pitcher => |p| {
                if (!p.on) continue;
                const hi: u16 = @as(u16, p.lowest) + p.range;
                for (cur.items) |sn| {
                    if (sn.note < p.lowest or sn.note > hi) continue;
                    const nn: i32 = @as(i32, sn.note) + p.pitch;
                    if (nn < 0 or nn > 127) continue;
                    var copy = sn;
                    copy.note = @intCast(nn);
                    try next.append(a, copy);
                }
            },
            .chord => |ch| {
                if (!ch.on) continue;
                for (cur.items) |sn| {
                    if (next.items.len >= max_sim_notes) break;
                    try next.append(a, sn);
                    for (0..6) |k| {
                        const sh = ch.shifts[k];
                        if (sh == 0) continue;
                        const nn: i32 = @as(i32, sn.note) + sh;
                        if (nn < 0 or nn > 127) continue;
                        if (next.items.len >= max_sim_notes) break;
                        const nv: u8 = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(sn.vel)) * ch.vels[k]), 1.0, 127.0));
                        try next.append(a, .{
                            .start_ms = sn.start_ms,
                            .dur_ms = sn.dur_ms,
                            .note = @intCast(nn),
                            .vel = nv,
                        });
                    }
                }
            },
            .velocity => |ve| {
                if (!ve.on) continue;
                const lo: u8 = ve.lowest;
                const hi: u8 = @intCast(@min(@as(u16, 127), @as(u16, ve.lowest) + ve.range));
                // Live 9/10 uses Operation (0=Clip, 1=Gate, 2=Fixed); some schemas/tools use Mode (2=Fixed).
                const is_fixed = ve.mode == 2 or ve.operation == 2;
                const is_gate = !is_fixed and (ve.mode == 1 or ve.operation == 1);
                for (cur.items) |sn| {
                    if (is_gate and (sn.vel < lo or sn.vel > hi)) continue;
                    var copy = sn;
                    copy.vel = if (is_fixed) ve.max_out else blk: {
                        // Clip / Gate linear scaling [lo..hi] -> [min_out..max_out]
                        const clamped = std.math.clamp(sn.vel, lo, hi);
                        if (hi <= lo) break :blk ve.max_out;
                        const t = @as(f64, @floatFromInt(clamped - lo)) / @as(f64, @floatFromInt(hi - lo));
                        const out_f = @as(f64, @floatFromInt(ve.min_out)) + t * (@as(f64, @floatFromInt(ve.max_out)) - @as(f64, @floatFromInt(ve.min_out)));
                        break :blk @intFromFloat(std.math.clamp(@round(out_f), 0.0, 127.0));
                    };
                    try next.append(a, copy);
                }
            },
            .note_length => |nl| {
                if (!nl.on) continue;
                const base_ms: f64 = if (nl.sync_state) syncedLengthBeats(nl.synced_len) * beat_ms else @floatCast(nl.time_ms);
                const dur = @max(base_ms * (@as(f64, nl.gate) / 100.0), 1.0);
                for (cur.items) |sn| {
                    var copy = sn;
                    if (nl.trigger_off) copy.start_ms += sn.dur_ms;
                    copy.dur_ms = dur;
                    try next.append(a, copy);
                }
            },
            .arp => |ar| {
                if (!ar.on) continue;
                try evalArp(a, ar, beat_ms, cur.items, &next);
            },
            .random => |rnd| {
                if (!rnd.on) continue;
                if (rnd.alternate and rnd.chance >= 0.5 and rnd.choices > 1) {
                    cycle_len.* = @min(@as(usize, 24), lcmUsize(cycle_len.*, rnd.choices));
                    const step: i32 = @intCast(press_idx % rnd.choices);
                    const shift: i32 = if (rnd.sign == 1) -step * @as(i32, rnd.scale) else step * @as(i32, rnd.scale);
                    for (cur.items) |sn| {
                        const nn = @as(i32, sn.note) + shift;
                        if (nn < 0 or nn > 127) continue;
                        var copy = sn;
                        copy.note = @intCast(nn);
                        try next.append(a, copy);
                    }
                } else {
                    const rem = max_sim_notes -| next.items.len;
                    try next.appendSlice(a, cur.items[0..@min(cur.items.len, rem)]);
                }
            },
            .mx_ext => |mx| {
                if (!mx.on) continue;
                if (try resolveMidiExtNotes(a, midiext, mx.lom_id)) |seq| {
                    for (cur.items) |sn| {
                        for (seq) |mn| {
                            if (next.items.len >= max_sim_notes) break;
                            try next.append(a, .{
                                .start_ms = sn.start_ms + mn.start_ms,
                                .dur_ms = mn.dur_ms,
                                .note = mn.note,
                                .vel = mn.vel,
                            });
                        }
                    }
                } else {
                    const rem = max_sim_notes -| next.items.len;
                    try next.appendSlice(a, cur.items[0..@min(cur.items.len, rem)]);
                }
            },
        }
        std.mem.swap(std.ArrayList(SimNote), &cur, &next);
    }

    const rem = max_sim_notes -| out_notes.items.len;
    if (rem > 0) {
        try out_notes.appendSlice(a, cur.items[0..@min(cur.items.len, rem)]);
    }
}

fn evalArp(
    a: std.mem.Allocator,
    ar: @FieldType(MidiDev, "arp"),
    beat_ms: f64,
    in_notes: []const SimNote,
    out: *std.ArrayList(SimNote),
) !void {
    if (in_notes.len == 0) return;

    // Group simultaneous incoming notes (within 0.5ms) so nested Chords + Arps work accurately.
    var sorted = try a.dupe(SimNote, in_notes);
    defer a.free(sorted);
    std.mem.sort(SimNote, sorted, {}, struct {
        fn lt(_: void, x: SimNote, y: SimNote) bool {
            if (@abs(x.start_ms - y.start_ms) > 0.5) return x.start_ms < y.start_ms;
            return x.note < y.note;
        }
    }.lt);

    const step_ms: f64 = if (ar.sync_state) syncedRateBeats(ar.synced_rate) * beat_ms else @floatCast(ar.free_rate_ms);
    const note_dur: f64 = @max(step_ms * (@as(f64, ar.gate) / 100.0), 1.0);
    const reps: usize = if (ar.repeat_count == 0) 1 else @min(@as(usize, ar.repeat_count), 4);
    const t_steps: usize = @min(@as(usize, ar.transpose_steps), 4);

    var gi: usize = 0;
    while (gi < sorted.len and out.items.len < max_sim_notes) {
        const t0 = sorted[gi].start_ms;
        var gj = gi + 1;
        while (gj < sorted.len and @abs(sorted[gj].start_ms - t0) <= 0.5) : (gj += 1) {}

        // Unique pitches in this chord group (already sorted ascending)
        var uniq: [128]SimNote = undefined;
        var ulen: usize = 0;
        for (sorted[gi..gj]) |sn| {
            if (ulen == 0 or uniq[ulen - 1].note != sn.note) {
                uniq[ulen] = sn;
                ulen += 1;
            }
        }
        gi = gj;
        if (ulen == 0) continue;

        // Build pattern order for one cycle
        var pat: [256]SimNote = undefined;
        var plen: usize = 0;
        switch (ar.mode) {
            1 => { // Down
                var k: usize = ulen;
                while (k > 0) : (k -= 1) {
                    pat[plen] = uniq[k - 1];
                    plen += 1;
                }
            },
            2 => { // UpDown (no repeated endpoints)
                for (0..ulen) |k| {
                    pat[plen] = uniq[k];
                    plen += 1;
                }
                if (ulen > 2) {
                    var k: usize = ulen - 1;
                    while (k > 1) : (k -= 1) {
                        pat[plen] = uniq[k - 1];
                        plen += 1;
                    }
                }
            },
            3 => { // DownUp (no repeated endpoints)
                var k: usize = ulen;
                while (k > 0) : (k -= 1) {
                    pat[plen] = uniq[k - 1];
                    plen += 1;
                }
                if (ulen > 2) {
                    for (1..ulen - 1) |m| {
                        pat[plen] = uniq[m];
                        plen += 1;
                    }
                }
            },
            4 => { // Up & Down (with repeated endpoints)
                for (0..ulen) |k| {
                    pat[plen] = uniq[k];
                    plen += 1;
                }
                var k: usize = ulen;
                while (k > 0) : (k -= 1) {
                    pat[plen] = uniq[k - 1];
                    plen += 1;
                }
            },
            5 => { // Down & Up (with repeated endpoints)
                var k: usize = ulen;
                while (k > 0) : (k -= 1) {
                    pat[plen] = uniq[k - 1];
                    plen += 1;
                }
                for (0..ulen) |m| {
                    pat[plen] = uniq[m];
                    plen += 1;
                }
            },
            14 => { // Chord trigger: emit all simultaneously
                for (0..reps) |r| {
                    const rt = t0 + @as(f64, @floatFromInt(r)) * step_ms;
                    for (0..ulen) |k| {
                        if (out.items.len >= max_sim_notes) break;
                        try out.append(a, .{ .start_ms = rt, .dur_ms = note_dur, .note = uniq[k].note, .vel = uniq[k].vel });
                    }
                }
                continue;
            },
            else => { // 0 = Up (and default)
                for (0..ulen) |k| {
                    pat[plen] = uniq[k];
                    plen += 1;
                }
            },
        }

        var step_idx: usize = 0;
        for (0..reps) |_| {
            for (0..t_steps + 1) |ts| {
                const shift: i32 = @as(i32, @intCast(ts)) * ar.transpose_dist;
                for (pat[0..plen]) |sn| {
                    const nn = @as(i32, sn.note) + shift;
                    if (nn >= 0 and nn <= 127 and out.items.len < max_sim_notes) {
                        try out.append(a, .{
                            .start_ms = t0 + @as(f64, @floatFromInt(step_idx)) * step_ms,
                            .dur_ms = note_dur,
                            .note = @intCast(nn),
                            .vel = sn.vel,
                        });
                    }
                    step_idx += 1;
                }
            }
        }
    }
}

fn syncedRateBeats(idx: u8) f64 {
    // Ableton Live MidiArpeggiator SyncedRate (0=1/128 .. 14=1/1) in quarter-note beats.
    const table = [_]f64{
        1.0 / 32.0, // 0: 1/128
        1.0 / 24.0, // 1: 1/96
        1.0 / 16.0, // 2: 1/64
        1.0 / 12.0, // 3: 1/48
        1.0 / 8.0, // 4: 1/32
        1.0 / 6.0, // 5: 1/24
        1.0 / 4.0, // 6: 1/16
        1.0 / 3.0, // 7: 1/12
        1.0 / 2.0, // 8: 1/8
        2.0 / 3.0, // 9: 1/6
        1.0, // 10: 1/4
        4.0 / 3.0, // 11: 1/3
        2.0, // 12: 1/2
        3.0, // 13: 3/4
        4.0, // 14: 1/1
    };
    return table[@min(idx, table.len - 1)];
}

fn syncedLengthBeats(idx: u8) f64 {
    const table = [_]f64{
        1.0 / 16.0, // 0: 1/64
        1.0 / 8.0, // 1: 1/32
        1.0 / 4.0, // 2: 1/16
        1.0 / 2.0, // 3: 1/8
        1.0, // 4: 1/4
        2.0, // 5: 1/2
        4.0, // 6: 1/1
        8.0, // 7: 2/1
    };
    return table[@min(idx, table.len - 1)];
}

// ============================================================================
// Arrangement MidiClips -> AutoPlay
// ============================================================================

const AutoAction = struct {
    t_ms: u32,
    kind: enum(u8) { chain = 0, off = 1, on = 2 },
    a: u8,
    b: u8,
};

fn buildAutoPlay(
    a: std.mem.Allocator,
    parsed: *const ParsedAls,
    layout: NoteLayout,
    chain_count: u8,
) ![]const AutoPlayEvent {
    if (parsed.arr_clips.items.len == 0) return &.{};
    const beat_ms = 60000.0 / std.math.clamp(parsed.tempo, 20.0, 400.0);

    var raw_acts: std.ArrayList(AutoAction) = .empty;
    defer raw_acts.deinit(a);

    var min_t: u32 = std.math.maxInt(u32);

    for (parsed.arr_clips.items) |clip| {
        if (clip.end_beat <= clip.start_beat) continue;
        const clip_len = clip.end_beat - clip.start_beat;
        const clip_chain = parseClipChain(clip.name, chain_count);
        var added_note = false;
        var clip_first_t: u32 = std.math.maxInt(u32);

        for (clip.notes.items) |n| {
            if (n.beat < clip.loop_start or n.beat >= clip.loop_start + clip_len) continue;
            const song_beat = clip.start_beat + (n.beat - clip.loop_start);
            if (song_beat < 0) continue;
            const t_on: u32 = @intFromFloat(@round(song_beat * beat_ms));
            const t_off: u32 = @intFromFloat(@round((song_beat + @max(n.dur, 0.05)) * beat_ms));

            if (midiNoteToXY(layout, n.midi_key)) |xy| {
                added_note = true;
                if (t_on < clip_first_t) clip_first_t = t_on;
                if (t_on < min_t) min_t = t_on;
                try raw_acts.append(a, .{ .t_ms = t_on, .kind = .on, .a = xy[0], .b = xy[1] });
                try raw_acts.append(a, .{ .t_ms = t_off, .kind = .off, .a = xy[0], .b = xy[1] });
            } else if (n.midi_key >= 100 and n.midi_key <= 107) {
                const ch: u8 = n.midi_key - 100;
                if (ch < chain_count) {
                    try raw_acts.append(a, .{ .t_ms = t_on, .kind = .chain, .a = ch, .b = 0 });
                }
            }
        }

        if (added_note) {
            if (clip_chain) |ch| {
                try raw_acts.append(a, .{ .t_ms = clip_first_t, .kind = .chain, .a = ch, .b = 0 });
            }
        }
    }

    if (raw_acts.items.len == 0 or min_t == std.math.maxInt(u32)) return &.{};

    std.mem.sort(AutoAction, raw_acts.items, {}, struct {
        fn lt(_: void, x: AutoAction, y: AutoAction) bool {
            if (x.t_ms != y.t_ms) return x.t_ms < y.t_ms;
            return @intFromEnum(x.kind) < @intFromEnum(y.kind);
        }
    }.lt);

    var events: std.ArrayList(AutoPlayEvent) = .empty;
    var cur_t: u32 = min_t;
    var last_chain: ?u8 = null;

    for (raw_acts.items) |act| {
        if (act.t_ms < min_t) continue;
        if (act.kind == .chain and last_chain != null and last_chain.? == act.a) continue;
        if (act.t_ms > cur_t) {
            try events.append(a, .{ .delay = act.t_ms - cur_t });
            cur_t = act.t_ms;
        }
        switch (act.kind) {
            .chain => {
                last_chain = act.a;
                try events.append(a, .{ .chain = act.a });
            },
            .on => try events.append(a, .{ .on = .{ .row = act.a, .col = act.b } }),
            .off => try events.append(a, .{ .off = .{ .row = act.a, .col = act.b } }),
        }
    }
    return events.items;
}

fn parseClipChain(name: []const u8, chain_count: u8) ?u8 {
    // Matches "Page 1", "Page 3.1", "Chain 2", "Ch 4", etc.
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (std.ascii.isDigit(name[i])) {
            var j = i;
            while (j < name.len and std.ascii.isDigit(name[j])) : (j += 1) {}
            const n = std.fmt.parseInt(u8, name[i..j], 10) catch return null;
            if (n >= 1 and n <= chain_count) return n - 1;
            return null;
        }
    }
    return null;
}

// ============================================================================
// Launchpad Note Mapping & File Resolution Helpers
// ============================================================================

fn detectLayout(samples: []const PadMapping) NoteLayout {
    var prog_only: usize = 0;
    var user1_only: usize = 0;
    for (samples) |pm| {
        const n = pm.midi_note;
        if (n >= 36 and n <= 99) {
            const ones = n % 10;
            if (n >= 89 or ones == 0 or ones == 9) user1_only += 1;
        }
        if (n >= 11 and n < 36) {
            const r = n / 10;
            const col = n % 10;
            if (r >= 1 and r <= 3 and col >= 1 and col <= 8) prog_only += 1;
        }
    }
    if (user1_only == 0 and prog_only > 0) return .programmer;
    return .user1;
}

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

/// Maps outer ring LEDs (Top 0..7, Right 8..15, Bottom 16..23, Left 24..31, Logo 32)
/// matching UniPack `mc 1..32` / `l` indices for both User 1 (Drum Rack) and Programmer layouts.
pub fn midiNoteToRing(layout: NoteLayout, note: u8) ?u8 {
    switch (layout) {
        .user1 => {
            if (note >= 28 and note <= 35) return note - 28; // Top (left -> right): mc 1..8
            if (note >= 100 and note <= 107) return 8 + (note - 100); // Right (top -> bottom): mc 9..16
            if (note >= 108 and note <= 115) return 16 + (note - 108); // Bottom (right -> left): mc 17..24
            if (note >= 116 and note <= 123) return 24 + (note - 116); // Left (bottom -> top): mc 25..32
            if (note == 27) return types.logo_led_index; // Logo: l
            return null;
        },
        .programmer => {
            if (note >= 91 and note <= 98) return note - 91; // Top (left -> right): mc 1..8
            if (note >= 104 and note <= 111) return note - 104; // Top (MK2/S CC/note alt): mc 1..8
            if (note == 99) return types.logo_led_index; // Logo: l
            if (note >= 1 and note <= 8) return 16 + (8 - note); // Bottom (right -> left): mc 17..24
            // Right column: 89, 79, 69, 59, 49, 39, 29, 19 -> 8..15
            if (note >= 19 and note <= 89 and note % 10 == 9) return 8 + (8 - note / 10);
            // Left column: 10, 20, 30, 40, 50, 60, 70, 80 -> 24..31
            if (note >= 10 and note <= 80 and note % 10 == 0) return 24 + (note / 10 - 1);
            return null;
        },
    }
}

/// Detects 2-color Red/Green Launchpad MIDI output targets (Launchpad S, Launchpad Mini MK1/MK2,
/// or Live 8/9 plain Launchpad MK1 on Ch. 1). RGB models (MK2, Pro, X, Mini MK3) return false.
fn isLegacyLaunchpadTarget(target: []const u8, ch: i32, major_version: u16) bool {
    if (!containsIgnoreCase(target, "launchpad")) return false;
    if (containsIgnoreCase(target, "mk2") or
        containsIgnoreCase(target, "mk3") or
        containsIgnoreCase(target, "pro") or
        containsIgnoreCase(target, "rgb") or
        containsIgnoreCase(target, "cfw") or
        containsIgnoreCase(target, "lpx") or
        containsIgnoreCase(target, "launchpad x") or
        containsIgnoreCase(target, "launchpad_x") or
        containsIgnoreCase(target, "apollo"))
    {
        return false;
    }
    if (containsIgnoreCase(target, "launchpad s") or
        containsIgnoreCase(target, "launchpad_s") or
        containsIgnoreCase(target, "launchpad mini") or
        containsIgnoreCase(target, "launchpad_mini"))
    {
        return true;
    }
    return ch == 0 and major_version <= 4;
}

/// Maps Launchpad S / Mini MK1/MK2 2-bit R/G velocity (`r = v & 3`, `g = (v >> 4) & 3`)
/// to its closest Novation RGB Launchpad velocity (0 = off).
pub fn launchpadSToRgbVelocity(vel: u8) u8 {
    const r: usize = vel & 0x03;
    const g: usize = (vel >> 4) & 0x03;
    // Indexed [g][r] in 0..3 x 0..3 matching palette.zig Novation RGB entries.
    const table = [4][4]u8{
        .{ 0, 7, 6, 5 }, // g=0: off, dim red, med red, bright red
        .{ 23, 15, 10, 9 }, // g=1: dim green, dim yellow, med orange, bright orange
        .{ 22, 18, 14, 12 }, // g=2: med green, med lime, med yellow, warm amber
        .{ 21, 17, 16, 13 }, // g=3: bright green, bright lime, yellow-green, bright yellow
    };
    return table[g][r];
}

// ============================================================================
// Pure-Zig Sample Trimming (Simpler SampleStart/SampleEnd) & Layer Mixing
// ============================================================================

const WavSlice = struct {
    audio_fmt: u16,
    channels: u16,
    sample_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    data: []const u8,
    total_frames: u64,
};

fn parseWav(bytes: []const u8) ?WavSlice {
    if (bytes.len < 44) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return null;
    var pos: usize = 12;
    var audio_fmt: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var block_align: u16 = 0;
    var bits_per_sample: u16 = 0;
    var has_fmt = false;
    var data_slice: ?[]const u8 = null;

    while (pos + 8 <= bytes.len) {
        const cid = bytes[pos .. pos + 4];
        const csz: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const cstart = pos + 8;
        const cend = @min(bytes.len, cstart + csz);
        if (std.mem.eql(u8, cid, "fmt ") and cend - cstart >= 16) {
            audio_fmt = std.mem.readInt(u16, bytes[cstart..][0..2], .little);
            channels = std.mem.readInt(u16, bytes[cstart + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[cstart + 4 ..][0..4], .little);
            block_align = std.mem.readInt(u16, bytes[cstart + 12 ..][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, bytes[cstart + 14 ..][0..2], .little);
            if (audio_fmt == 0xFFFE and cend - cstart >= 40) {
                audio_fmt = std.mem.readInt(u16, bytes[cstart + 24 ..][0..2], .little);
            }
            has_fmt = true;
        } else if (std.mem.eql(u8, cid, "data")) {
            data_slice = bytes[cstart..cend];
        }
        const adv = csz + (csz & 1);
        if (cstart + adv <= pos) break;
        pos = cstart + adv;
    }

    if (!has_fmt or data_slice == null or channels == 0 or block_align == 0 or sample_rate == 0) return null;
    if (audio_fmt != 1 and audio_fmt != 3) return null;
    const d = data_slice.?;
    return .{
        .audio_fmt = audio_fmt,
        .channels = channels,
        .sample_rate = sample_rate,
        .block_align = block_align,
        .bits_per_sample = bits_per_sample,
        .data = d,
        .total_frames = d.len / block_align,
    };
}

fn shouldTrimSample(pm: PadMapping, vf: VirtualFile) bool {
    if (pm.sample_start > 0) return true;
    if (pm.sample_end == 0) return false;
    if (pm.default_duration > 0 and pm.sample_end + 64 < pm.default_duration) return true;
    if (endsWithIgnoreCase(vf.rel_path, ".wav")) {
        if (parseWav(vf.bytes)) |w| {
            if (pm.sample_end + 64 < w.total_frames) return true;
        }
    }
    return false;
}

fn trimSampleFile(
    a: std.mem.Allocator,
    vf: VirtualFile,
    start_frame: u64,
    end_frame: u64,
    default_sr: u32,
) !?VirtualFile {
    if (endsWithIgnoreCase(vf.rel_path, ".wav")) {
        if (try trimWavBytes(a, vf.bytes, start_frame, end_frame)) |out| {
            return .{ .rel_path = vf.rel_path, .bytes = out };
        }
        return null;
    }

    // Desktop: sample-accurate decode + slice -> 16-bit stereo PCM WAV for non-WAV formats (.mp3/.ogg/.flac/.aif)
    if (!is_wasm) {
        const sr: u32 = if (default_sr >= 8000 and default_sr <= 192000) default_sr else 44100;
        if (decode.decode(a, vf.bytes, vf.rel_path, sr)) |samp| {
            defer a.free(samp.data);
            const total_frames: u64 = samp.data.len / 2;
            if (total_frames > 0) {
                const s = @min(start_frame, total_frames);
                const e = if (end_frame > s) @min(end_frame, total_frames) else total_frames;
                if (e > s and (s > 0 or e + 64 < total_frames)) {
                    const pcm_slice = samp.data[@intCast(s * 2)..@intCast(e * 2)];
                    const wav_bytes = try encodeStereoPcm16Wav(a, pcm_slice, sr);
                    const stem = stemOfPath(vf.rel_path);
                    const new_name = try std.fmt.allocPrint(a, "{s}_trim.wav", .{stem});
                    return .{ .rel_path = new_name, .bytes = wav_bytes };
                }
            }
        } else |_| {}
    }

    // WASM (or fallback): pure-Zig MPEG frame-boundary trimmer for MP3
    if (endsWithIgnoreCase(vf.rel_path, ".mp3")) {
        if (try trimMp3Bytes(a, vf.bytes, start_frame, end_frame)) |out| {
            return .{ .rel_path = vf.rel_path, .bytes = out };
        }
    }
    return null;
}

fn trimWavBytes(a: std.mem.Allocator, bytes: []const u8, start_frame: u64, end_frame: u64) !?[]u8 {
    const w = parseWav(bytes) orelse return null;
    if (w.total_frames == 0) return null;
    const s = @min(start_frame, w.total_frames);
    const e = if (end_frame > s) @min(end_frame, w.total_frames) else w.total_frames;
    if (e <= s) return null;
    if (s == 0 and e + 64 >= w.total_frames) return null;

    const byte_start: usize = @intCast(s * w.block_align);
    const byte_end: usize = @intCast(e * w.block_align);
    if (byte_end > w.data.len or byte_end <= byte_start) return null;
    const payload = w.data[byte_start..byte_end];
    if (payload.len > std.math.maxInt(u32) - 44) return null;

    const out = try a.alloc(u8, 44 + payload.len);
    const data_sz: u32 = @intCast(payload.len);
    const riff_sz: u32 = 36 + data_sz;
    const byte_rate: u32 = w.sample_rate * w.block_align;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], riff_sz, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], w.audio_fmt, .little);
    std.mem.writeInt(u16, out[22..24], w.channels, .little);
    std.mem.writeInt(u32, out[24..28], w.sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], byte_rate, .little);
    std.mem.writeInt(u16, out[32..34], w.block_align, .little);
    std.mem.writeInt(u16, out[34..36], w.bits_per_sample, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_sz, .little);
    @memcpy(out[44..], payload);
    return out;
}

fn trimMp3Bytes(a: std.mem.Allocator, bytes: []const u8, start_frame: u64, end_frame: u64) !?[]u8 {
    if (bytes.len < 16) return null;
    var pos: usize = 0;
    if (std.mem.eql(u8, bytes[0..3], "ID3") and bytes.len >= 10) {
        const id3_sz: usize = (@as(usize, bytes[6] & 0x7F) << 21) |
            (@as(usize, bytes[7] & 0x7F) << 14) |
            (@as(usize, bytes[8] & 0x7F) << 7) |
            @as(usize, bytes[9] & 0x7F);
        pos = @min(bytes.len, 10 + id3_sz);
    }

    const br_v1_l3 = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    const br_v2_l3 = [16]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
    const sr_v1 = [4]u32{ 44100, 48000, 32000, 0 };
    const sr_v2 = [4]u32{ 22050, 24000, 16000, 0 };
    const sr_v25 = [4]u32{ 11025, 12000, 8000, 0 };

    var cur_sample: u64 = 0;
    var slice_start: ?usize = null;
    var slice_end: usize = bytes.len;
    var skipped_xing = false;

    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xFF or (bytes[pos + 1] & 0xE0) != 0xE0) {
            pos += 1;
            continue;
        }
        const ver = (bytes[pos + 1] >> 3) & 0x03;
        const layer = (bytes[pos + 1] >> 1) & 0x03;
        const br_i = (bytes[pos + 2] >> 4) & 0x0F;
        const sr_i = (bytes[pos + 2] >> 2) & 0x03;
        const pad: usize = (bytes[pos + 2] >> 1) & 0x01;
        if (ver == 1 or layer != 1 or br_i == 0 or br_i == 15 or sr_i == 3) {
            pos += 1;
            continue;
        }
        const br: u32 = (if (ver == 3) br_v1_l3[br_i] else br_v2_l3[br_i]) * 1000;
        const sr: u32 = switch (ver) {
            3 => sr_v1[sr_i],
            2 => sr_v2[sr_i],
            0 => sr_v25[sr_i],
            else => 0,
        };
        if (br == 0 or sr == 0) {
            pos += 1;
            continue;
        }
        const spf: u64 = if (ver == 3) 1152 else 576;
        const fsz: usize = @intCast(((if (ver == 3) @as(u64, 144) else @as(u64, 72)) * br) / sr + pad);
        if (fsz < 4 or pos + fsz > bytes.len) break;

        if (!skipped_xing and cur_sample == 0) {
            skipped_xing = true;
            const frame = bytes[pos .. pos + fsz];
            if (std.mem.indexOf(u8, frame, "Xing") != null or std.mem.indexOf(u8, frame, "Info") != null) {
                pos += fsz;
                continue;
            }
        }

        if (slice_start == null and cur_sample + spf > start_frame) {
            slice_start = pos;
        }
        cur_sample += spf;
        pos += fsz;
        if (end_frame > start_frame and cur_sample >= end_frame) {
            slice_end = pos;
            break;
        }
    }

    const s_off = slice_start orelse return null;
    if (slice_end <= s_off or slice_end > bytes.len) return null;
    return try a.dupe(u8, bytes[s_off..slice_end]);
}

fn encodeStereoPcm16Wav(a: std.mem.Allocator, stereo_f32: []const f32, sample_rate: u32) ![]u8 {
    const data_sz: u32 = @intCast(stereo_f32.len * 2);
    const out = try a.alloc(u8, 44 + data_sz);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_sz, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 2, .little); // stereo
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * 4, .little);
    std.mem.writeInt(u16, out[32..34], 4, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_sz, .little);
    for (stereo_f32, 0..) |s, i| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        const v: i16 = @intFromFloat(@round(clamped * 32767.0));
        std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], v, .little);
    }
    return out;
}

fn readWavSampleF32(w: WavSlice, frame: usize, ch: usize) f32 {
    const c_idx = if (ch < w.channels) ch else 0;
    const bps_bytes: usize = w.bits_per_sample / 8;
    const off = frame * w.block_align + c_idx * bps_bytes;
    if (off + bps_bytes > w.data.len) return 0.0;
    if (w.audio_fmt == 3 and w.bits_per_sample == 32) {
        return @bitCast(std.mem.readInt(u32, w.data[off..][0..4], .little));
    }
    return switch (w.bits_per_sample) {
        8 => (@as(f32, @floatFromInt(w.data[off])) - 128.0) / 128.0,
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, w.data[off..][0..2], .little))) / 32768.0,
        24 => blk: {
            const b0: i32 = w.data[off];
            const b1: i32 = w.data[off + 1];
            const b2: i32 = @as(i8, @bitCast(w.data[off + 2]));
            const val: i32 = (b2 << 16) | (b1 << 8) | b0;
            break :blk @as(f32, @floatFromInt(val)) / 8388608.0;
        },
        32 => @as(f32, @floatFromInt(std.mem.readInt(i32, w.data[off..][0..4], .little))) / 2147483648.0,
        else => 0.0,
    };
}

fn mixWavLayers(a: std.mem.Allocator, raw_sounds: []const VirtualFile, entries: []const SoundEntry) !?[]u8 {
    if (entries.len <= 1 or entries.len > 16) return null;
    var wavs: [16]WavSlice = undefined;
    var sample_rate: u32 = 0;
    var max_frames: usize = 0;

    for (entries, 0..) |se, i| {
        const w = parseWav(raw_sounds[se.sample_id].bytes) orelse return null;
        if (w.bits_per_sample != 8 and w.bits_per_sample != 16 and w.bits_per_sample != 24 and w.bits_per_sample != 32) return null;
        if (i == 0) {
            sample_rate = w.sample_rate;
        } else if (w.sample_rate != sample_rate) {
            return null;
        }
        if (w.total_frames > 44100 * 60) return null; // safety cap: 60s
        wavs[i] = w;
        max_frames = @max(max_frames, @as(usize, @intCast(w.total_frames)));
    }
    if (max_frames == 0) return null;

    const mix = try a.alloc(f32, max_frames * 2);
    defer a.free(mix);
    @memset(mix, 0.0);

    var peak: f32 = 0.0;
    for (wavs[0..entries.len]) |w| {
        const n: usize = @intCast(w.total_frames);
        for (0..n) |f| {
            const l = readWavSampleF32(w, f, 0);
            const r = readWavSampleF32(w, f, 1);
            mix[f * 2] += l;
            mix[f * 2 + 1] += r;
            peak = @max(peak, @max(@abs(mix[f * 2]), @abs(mix[f * 2 + 1])));
        }
    }
    if (peak > 0.98) {
        const scale = 0.98 / peak;
        for (mix) |*s| s.* *= scale;
    }
    return try encodeStereoPcm16Wav(a, mix, sample_rate);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn resolveSampleFile(
    a: std.mem.Allocator,
    rel_path: []const u8,
    file_name: []const u8,
    files: []const VirtualFile,
    path_index: *const std.StringHashMapUnmanaged(VirtualFile),
    base_index: *const std.StringHashMapUnmanaged(?VirtualFile),
) ?VirtualFile {
    // Build normalized candidate tail: e.g. "page 1/2.wav"
    var candidate_buf: std.ArrayList(u8) = .empty;
    defer candidate_buf.deinit(a);

    if (rel_path.len > 0) {
        for (rel_path) |ch| {
            const norm = if (ch == '\\') '/' else std.ascii.toLower(ch);
            candidate_buf.append(a, norm) catch return null;
        }
        if (file_name.len > 0 and !endsWithIgnoreCase(rel_path, file_name)) {
            if (candidate_buf.items[candidate_buf.items.len - 1] != '/') candidate_buf.append(a, '/') catch return null;
            for (file_name) |ch| candidate_buf.append(a, std.ascii.toLower(ch)) catch return null;
        }
    } else if (file_name.len > 0) {
        for (file_name) |ch| candidate_buf.append(a, std.ascii.toLower(ch)) catch return null;
    } else return null;

    var cand = candidate_buf.items;
    while (std.mem.startsWith(u8, cand, "../")) cand = cand[3..];
    while (std.mem.startsWith(u8, cand, "./")) cand = cand[2..];
    while (std.mem.startsWith(u8, cand, "/")) cand = cand[1..];

    if (path_index.get(cand)) |vf| return vf;

    // Suffix match (handles wrapper directories like "Open Here/../Page 1/2.wav")
    for (files) |f| {
        if (!isAudioFile(f.rel_path)) continue;
        if (f.rel_path.len >= cand.len) {
            const tail = f.rel_path[f.rel_path.len - cand.len ..];
            if (std.ascii.eqlIgnoreCase(tail, cand) and (f.rel_path.len == cand.len or f.rel_path[f.rel_path.len - cand.len - 1] == '/')) {
                return f;
            }
        }
    }

    // Fallback: unambiguous unique basename match (rescues moved sample dirs in older projects)
    const cand_base = basenameOf(cand);
    if (base_index.get(cand_base)) |maybe_vf| {
        if (maybe_vf) |vf| return vf;
    }
    return null;
}

fn isAudioFile(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".wav") or
        endsWithIgnoreCase(path, ".mp3") or
        endsWithIgnoreCase(path, ".ogg") or
        endsWithIgnoreCase(path, ".flac") or
        endsWithIgnoreCase(path, ".aif") or
        endsWithIgnoreCase(path, ".aiff");
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

fn extOf(path: []const u8) []const u8 {
    const base = basenameOf(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[dot..];
    return ".wav";
}

fn stemOfPath(path: []const u8) []const u8 {
    const base = basenameOf(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn lowerAlloc(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "ableton note mapping roundtrips user1 and programmer layouts" {
    // User 1 bottom-left = 36 -> (7, 0); top-right = 99 -> (0, 7)
    try std.testing.expectEqual(@as(?[2]u8, .{ 7, 0 }), midiNoteToXY(.user1, 36));
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 7 }), midiNoteToXY(.user1, 99));
    // Programmer bottom-left = 11 -> (7, 0); top-right = 88 -> (0, 7)
    try std.testing.expectEqual(@as(?[2]u8, .{ 7, 0 }), midiNoteToXY(.programmer, 11));
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 7 }), midiNoteToXY(.programmer, 88));
    for (0..8) |r| {
        for (0..8) |col| {
            const u1_note = xyToMidiNote(.user1, @intCast(r), @intCast(col));
            try std.testing.expectEqual(@as(?[2]u8, .{ @intCast(r), @intCast(col) }), midiNoteToXY(.user1, u1_note));
            const pg = xyToMidiNote(.programmer, @intCast(r), @intCast(col));
            try std.testing.expectEqual(@as(?[2]u8, .{ @intCast(r), @intCast(col) }), midiNoteToXY(.programmer, pg));
        }
    }
    // Side/Top/Bottom/Left/Logo ring LEDs
    try std.testing.expectEqual(@as(?u8, 0), midiNoteToRing(.user1, 28)); // Top left (mc 1)
    try std.testing.expectEqual(@as(?u8, 7), midiNoteToRing(.user1, 35)); // Top right (mc 8)
    try std.testing.expectEqual(@as(?u8, 8), midiNoteToRing(.user1, 100)); // Right top (mc 9)
    try std.testing.expectEqual(@as(?u8, 15), midiNoteToRing(.user1, 107)); // Right bottom (mc 16)
    try std.testing.expectEqual(@as(?u8, 16), midiNoteToRing(.user1, 108)); // Bottom (mc 17)
    try std.testing.expectEqual(@as(?u8, 24), midiNoteToRing(.user1, 116)); // Left (mc 25)
    try std.testing.expectEqual(@as(?u8, 32), midiNoteToRing(.user1, 27)); // Logo (l)

    try std.testing.expectEqual(@as(?u8, 0), midiNoteToRing(.programmer, 91)); // Top left
    try std.testing.expectEqual(@as(?u8, 8), midiNoteToRing(.programmer, 89)); // Right top
    try std.testing.expectEqual(@as(?u8, 15), midiNoteToRing(.programmer, 19)); // Right bottom
    try std.testing.expectEqual(@as(?u8, 16), midiNoteToRing(.programmer, 8)); // Bottom right
    try std.testing.expectEqual(@as(?u8, 24), midiNoteToRing(.programmer, 10)); // Left bottom
    try std.testing.expectEqual(@as(?u8, 32), midiNoteToRing(.programmer, 99)); // Logo
}

test "ableton streaming parser and lightshow simulator convert synthetic als" {
    const synthetic_als =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Ableton><LiveSet>
        \\  <Tracks>
        \\    <MidiTrack>
        \\      <DeviceChain>
        \\        <MainSequencer><ClipTimeable><ArrangerAutomation><Events>
        \\          <MidiClip Time="0"><Name Value="Page 1" /><CurrentStart Value="0" /><CurrentEnd Value="4" />
        \\            <Loop><LoopStart Value="0" /></Loop>
        \\            <Notes><KeyTracks><KeyTrack>
        \\              <MidiKey Value="36" />
        \\              <Notes><MidiNoteEvent Time="1.0" Duration="0.5" Velocity="127" /></Notes>
        \\            </KeyTrack></KeyTracks></Notes>
        \\          </MidiClip>
        \\        </Events></ArrangerAutomation></ClipTimeable></MainSequencer>
        \\        <DeviceChain><Devices>
        \\          <DrumGroupDevice><Branches>
        \\            <DrumBranch>
        \\              <DeviceChain><Devices><InstrumentGroupDevice><Branches>
        \\                <InstrumentBranch>
        \\                  <DeviceChain><Devices><OriginalSimpler>
        \\                    <On><Manual Value="true" /></On>
        \\                    <Player><MultiSampleMap><SampleParts><MultiSamplePart><SampleRef>
        \\                      <FileRef>
        \\                        <RelativePath><RelativePathElement Dir="" /><RelativePathElement Dir="Page 1" /></RelativePath>
        \\                        <Name Value="kick.wav" />
        \\                        <SearchHint><PathHint><RelativePathElement Dir="Users" /></PathHint></SearchHint>
        \\                      </FileRef>
        \\                      <OriginalFileRef><FileRef><RelativePath><RelativePathElement Dir="Page 1" /></RelativePath><Name Value="" /></FileRef></OriginalFileRef>
        \\                    </SampleRef></MultiSamplePart></SampleParts></MultiSampleMap></Player>
        \\                  </OriginalSimpler></Devices></DeviceChain>
        \\                  <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\                </InstrumentBranch>
        \\              </Branches></InstrumentGroupDevice></Devices></DeviceChain>
        \\              <BranchInfo><ReceivingNote Value="92" /></BranchInfo>
        \\            </DrumBranch>
        \\          </Branches></DrumGroupDevice>
        \\        </Devices></DeviceChain>
        \\      </DeviceChain>
        \\    </MidiTrack>
        \\    <MidiTrack>
        \\      <DeviceChain><DeviceChain><Devices>
        \\        <MidiEffectGroupDevice><On><Manual Value="true" /></On><Branches>
        \\          <MidiEffectBranch>
        \\            <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\            <ZoneSettings><KeyRange><Min Value="36" /><Max Value="36" /></KeyRange></ZoneSettings>
        \\            <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\              <MidiChord><On><Manual Value="true" /></On><Shift1><Manual Value="1" /></Shift1><Velocity1><Manual Value="1" /></Velocity1></MidiChord>
        \\              <MidiArpeggiator><On><Manual Value="true" /></On><Mode><Manual Value="0" /></Mode><SyncState><Manual Value="true" /></SyncState><SyncedRate><Manual Value="4" /></SyncedRate><RepeatCount><Manual Value="1" /></RepeatCount><Gate><Manual Value="100" /></Gate></MidiArpeggiator>
        \\              <MidiVelocity><On><Manual Value="true" /></On><Operation><Manual Value="2" /></Operation><MaxOut><Manual Value="45" /></MaxOut></MidiVelocity>
        \\            </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\          </MidiEffectBranch>
        \\        </Branches></MidiEffectGroupDevice>
        \\      </Devices></DeviceChain></DeviceChain>
        \\    </MidiTrack>
        \\  </Tracks>
        \\  <MasterTrack><DeviceChain><Mixer><Tempo><Manual Value="120" /></Tempo></Mixer></DeviceChain></MasterTrack>
        \\</LiveSet></Ableton>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const files = [_]VirtualFile{
        .{ .rel_path = "Open Here/Demo.als", .bytes = synthetic_als },
        .{ .rel_path = "Page 1/kick.wav", .bytes = "RIFF" },
    };
    const proj = try buildProject(a, &files, "Demo");
    try std.testing.expectEqualStrings("Demo", proj.title);
    try std.testing.expectEqual(@as(u8, 1), proj.chain_count);
    // Note 36 -> (row=7, col=0)
    const cell = 7 * 8 + 0;
    try std.testing.expectEqual(@as(usize, 1), proj.sound_cells[cell].len);
    // Chord(+1) + Arp(2 steps) -> 2 pads lit with velocity 45 -> at least 4 events (on, delay, off/on, delay, off)
    try std.testing.expectEqual(@as(usize, 1), proj.led_cells[cell].len);
    try std.testing.expect(proj.led_cells[cell][0].len >= 4);
    try std.testing.expectEqual(@as(u8, 45), proj.led_cells[cell][0][0].pad_on.velocity);
    // Arrangement clip -> AutoPlay has chain + on + delay + off
    try std.testing.expect(proj.auto_play.len >= 3);

    // Bundled Public Domain LinnDrum LM-2 + TR-909 + CC0 TR-808 + GPLv2+ LMMS drum bank matches and decodes cleanly
    const ld = drums_bank.lookup("Samples/Drums/Kick", "Kick-LD.aif") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ld_kick.wav", ld.name);
    const s909 = drums_bank.lookup("Samples/Drums/Snare", "Snare-909-Tune8-s.wav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("909_snare.wav", s909.name);
    for (drums_bank.all_assets) |asset| {
        const decoded = try decode.decode(std.testing.allocator, asset.bytes, asset.name, 48000);
        defer std.testing.allocator.free(decoded.data);
        try std.testing.expect(decoded.frames() > 500);
    }
}

test "ableton keytrack backfill, heart wrapper+velocity scaling, outer inst rack, and midi extension" {
    const als =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Ableton><LiveSet>
        \\  <Tracks>
        \\    <MidiTrack>
        \\      <DeviceChain>
        \\        <MainSequencer><ClipTimeable><ArrangerAutomation><Events>
        \\          <MidiClip Time="0"><Name Value="Page 1" /><CurrentStart Value="0" /><CurrentEnd Value="4" />
        \\            <Loop><LoopStart Value="0" /></Loop>
        \\            <Notes><KeyTracks>
        \\              <KeyTrack>
        \\                <Notes><MidiNoteEvent Time="0.0" Duration="0.5" Velocity="127" /></Notes>
        \\                <MidiKey Value="36" />
        \\              </KeyTrack>
        \\              <KeyTrack>
        \\                <Notes><MidiNoteEvent Time="1.0" Duration="0.5" Velocity="127" /></Notes>
        \\                <MidiKey Value="51" />
        \\              </KeyTrack>
        \\            </KeyTracks></Notes>
        \\          </MidiClip>
        \\        </Events></ArrangerAutomation></ClipTimeable></MainSequencer>
        \\        <DeviceChain><Devices>
        \\          <InstrumentGroupDevice><Branches>
        \\            <InstrumentBranch>
        \\              <DeviceChain><Devices><DrumGroupDevice><Branches>
        \\                <DrumBranch>
        \\                  <DeviceChain><Devices><OriginalSimpler>
        \\                    <On><Manual Value="true" /></On>
        \\                    <Player><MultiSampleMap><SampleParts><MultiSamplePart><SampleRef>
        \\                      <FileRef><RelativePath Value="Samples/kick.wav" /><Name Value="kick.wav" /></FileRef>
        \\                    </SampleRef></MultiSamplePart></SampleParts></MultiSampleMap></Player>
        \\                  </OriginalSimpler></Devices></DeviceChain>
        \\                  <BranchInfo><ReceivingNote Value="92" /></BranchInfo>
        \\                </DrumBranch>
        \\              </Branches></DrumGroupDevice></Devices></DeviceChain>
        \\              <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\            </InstrumentBranch>
        \\          </Branches></InstrumentGroupDevice>
        \\        </Devices></DeviceChain>
        \\      </DeviceChain>
        \\    </MidiTrack>
        \\    <MidiTrack>
        \\      <DeviceChain>
        \\        <MidiOutputRouting><Target Value="MidiOut/External.Dev:Launchpad/2" /></MidiOutputRouting>
        \\        <DeviceChain><Devices>
        \\        <MidiEffectGroupDevice><On><Manual Value="true" /></On><Branches>
        \\          <MidiEffectBranch>
        \\            <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\            <ZoneSettings><KeyRange><Min Value="51" /><Max Value="51" /></KeyRange></ZoneSettings>
        \\            <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\              <MidiEffectGroupDevice><On><Manual Value="true" /></On><Branches>
        \\                <MidiEffectBranch>
        \\                  <ZoneSettings><KeyRange><Min Value="43" /><Max Value="43" /></KeyRange></ZoneSettings>
        \\                  <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\                    <MidiEffectGroupDevice><On><Manual Value="true" /></On><Branches>
        \\                      <MidiEffectBranch>
        \\                        <ZoneSettings><KeyRange><Min Value="51" /><Max Value="51" /></KeyRange></ZoneSettings>
        \\                        <DeviceChain><MidiToMidiDeviceChain><Devices /></MidiToMidiDeviceChain></DeviceChain>
        \\                      </MidiEffectBranch>
        \\                      <MidiEffectBranch>
        \\                        <ZoneSettings><KeyRange><Min Value="51" /><Max Value="51" /></KeyRange></ZoneSettings>
        \\                        <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\                          <MidiPitcher><On><Manual Value="true" /></On><Pitch><Manual Value="1" /></Pitch></MidiPitcher>
        \\                          <MidiVelocity><On><Manual Value="true" /></On><Mode><Manual Value="0" /></Mode><MinOut><Manual Value="1" /></MinOut><MaxOut><Manual Value="60" /></MaxOut></MidiVelocity>
        \\                        </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\                      </MidiEffectBranch>
        \\                    </Branches></MidiEffectGroupDevice>
        \\                    <MidiVelocity><On><Manual Value="true" /></On><Mode><Manual Value="0" /></Mode><MinOut><Manual Value="1" /></MinOut><MaxOut><Manual Value="5" /></MaxOut><Lowest><Manual Value="1" /></Lowest><Range><Manual Value="127" /></Range></MidiVelocity>
        \\                    <MidiNoteLength><On><Manual Value="true" /></On><SyncState><Manual Value="false" /></SyncState><TimeLength><Manual Value="2000" /></TimeLength><Gate><Manual Value="100" /></Gate></MidiNoteLength>
        \\                  </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\                </MidiEffectBranch>
        \\              </Branches></MidiEffectGroupDevice>
        \\            </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\          </MidiEffectBranch>
        \\          <MidiEffectBranch>
        \\            <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\            <ZoneSettings><KeyRange><Min Value="36" /><Max Value="36" /></KeyRange></ZoneSettings>
        \\            <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\              <MidiRandom><On><Manual Value="true" /></On><Chance><Manual Value="1" /></Chance><Choices><Manual Value="2" /></Choices><Scale><Manual Value="1" /></Scale><Sign><Manual Value="0" /></Sign><Alternate><Manual Value="true" /></Alternate></MidiRandom>
        \\              <MidiEffectGroupDevice><On><Manual Value="true" /></On><Branches>
        \\                <MidiEffectBranch>
        \\                  <ZoneSettings><KeyRange><Min Value="36" /><Max Value="36" /></KeyRange></ZoneSettings>
        \\                  <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\                    <MxDeviceMidiEffect Id="0"><LomId Value="13" /><On><Manual Value="true" /></On></MxDeviceMidiEffect>
        \\                  </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\                </MidiEffectBranch>
        \\                <MidiEffectBranch>
        \\                  <ZoneSettings><KeyRange><Min Value="37" /><Max Value="37" /></KeyRange></ZoneSettings>
        \\                  <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\                    <MidiVelocity><On><Manual Value="true" /></On><Mode><Manual Value="2" /></Mode><MaxOut><Manual Value="55" /></MaxOut></MidiVelocity>
        \\                  </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\                </MidiEffectBranch>
        \\              </Branches></MidiEffectGroupDevice>
        \\            </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\          </MidiEffectBranch>
        \\        </Branches></MidiEffectGroupDevice>
        \\      </Devices></DeviceChain></DeviceChain>
        \\    </MidiTrack>
        \\  </Tracks>
        \\  <MasterTrack><DeviceChain><Mixer><Tempo><Manual Value="120" /></Tempo></Mixer></DeviceChain></MasterTrack>
        \\</LiveSet></Ableton>
    ;

    // Minimal SMF Type 0: 1 track, 480 TPQN, Note On 40 vel 21 at tick 0, Note Off 40 at tick 240
    const mini_mid = [_]u8{
        'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0,
        'M', 'T', 'r', 'k', 0, 0, 0, 13,
        0x00, 0x90, 40, 21,
        0x81, 0x70, 0x80, 40, 0,
        0x00, 0xFF, 0x2F, 0x00,
    };
    const zero_save =
        "id13midifile, id13midifile ./MIDIext/Demo/1-1.mid;\n" ++
        "id13temp1, id13temp1 120;\n" ++
        "id13temp2, id13temp2 120;\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const files = [_]VirtualFile{
        .{ .rel_path = "Sub/Old.als", .bytes = "<Ableton/>" },
        .{ .rel_path = "Main.als", .bytes = als },
        .{ .rel_path = "Samples/kick.wav", .bytes = "RIFF" },
        .{ .rel_path = "Sub/0save", .bytes = zero_save },
        .{ .rel_path = "MIDIext/Demo/1-1.mid", .bytes = &mini_mid },
    };

    const proj = try buildProject(a, &files, "Fallback");
    // Root Main.als preferred over nested Sub/Old.als
    try std.testing.expectEqualStrings("Main", proj.title);
    // Outer InstrumentBranch -> DrumGroupDevice -> kick.wav on note 36 (row 7, col 0)
    try std.testing.expectEqual(@as(usize, 1), proj.sound_cells[7 * 8 + 0].len);

    // KeyTrack backfill: both notes 36 (7,0) and 51 (4,3) present in AutoPlay
    var saw_36 = false;
    var saw_51 = false;
    for (proj.auto_play) |ev| {
        if (ev == .on) {
            if (ev.on.row == 7 and ev.on.col == 0) saw_36 = true;
            if (ev.on.row == 4 and ev.on.col == 3) saw_51 = true;
        }
    }
    try std.testing.expect(saw_36 and saw_51);

    // Heart LED wrapper rescue + linear MidiVelocity + Glowing track breathing pulse:
    // pad 51 (4,3) emits vel 5 (red), vel 3 (white), and dimmed pulse color frames over 2000ms
    try std.testing.expectEqual(@as(usize, 1), proj.led_cells[4 * 8 + 3].len);
    const heart_evs = proj.led_cells[4 * 8 + 3][0];
    var saw_red = false;
    var saw_white = false;
    var saw_dimmed_pulse = false;
    for (heart_evs) |ev| {
        if (ev == .pad_on) {
            if (ev.pad_on.velocity == 5) saw_red = true;
            if (ev.pad_on.velocity == 3) saw_white = true;
            if (ev.pad_on.color != palette.argbOf(ev.pad_on.velocity)) saw_dimmed_pulse = true;
        }
    }
    try std.testing.expect(saw_red and saw_white and saw_dimmed_pulse);

    // MidiRandom(Choices=2, Alt=true) + MIDI Extension on pad 36 (7,0):
    // press 1 -> 1-1.mid note 40 (6,0) vel 21; press 2 -> shifted note 37 (7,1) vel 55
    const mx_anims = proj.led_cells[7 * 8 + 0];
    try std.testing.expectEqual(@as(usize, 2), mx_anims.len);
    try std.testing.expect(mx_anims[0].len >= 3);
    try std.testing.expectEqual(@as(u8, 6), mx_anims[0][0].pad_on.row);
    try std.testing.expectEqual(@as(u8, 0), mx_anims[0][0].pad_on.col);
    try std.testing.expectEqual(@as(u8, 21), mx_anims[0][0].pad_on.velocity);
    try std.testing.expect(mx_anims[1].len >= 3);
    try std.testing.expectEqual(@as(u8, 7), mx_anims[1][0].pad_on.row);
    try std.testing.expectEqual(@as(u8, 1), mx_anims[1][0].pad_on.col);
    try std.testing.expectEqual(@as(u8, 55), mx_anims[1][0].pad_on.velocity);
}

test "ableton live 9 legacy launchpad S colors, simpler trim, layer mix, and pure-zig zip" {
    try std.testing.expectEqual(@as(u8, 5), launchpadSToRgbVelocity(75)); // Bright Red
    try std.testing.expectEqual(@as(u8, 21), launchpadSToRgbVelocity(48)); // Bright Green
    try std.testing.expectEqual(@as(u8, 13), launchpadSToRgbVelocity(127)); // Bright Yellow
    try std.testing.expectEqual(@as(u8, 17), launchpadSToRgbVelocity(125)); // Bright Lime
    try std.testing.expectEqual(@as(u8, 9), launchpadSToRgbVelocity(31)); // Bright Orange
    try std.testing.expectEqual(@as(u8, 0), launchpadSToRgbVelocity(12)); // Off

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build two tiny valid 16-bit stereo 44.1kHz WAVs (1000 frames and 400 frames)
    const pcm_a = try a.alloc(f32, 1000 * 2);
    for (pcm_a, 0..) |*s, i| s.* = if (i % 2 == 0) 0.4 else -0.4;
    const wav_a = try encodeStereoPcm16Wav(a, pcm_a, 44100);

    const pcm_b = try a.alloc(f32, 400 * 2);
    @memset(pcm_b, 0.3);
    const wav_b = try encodeStereoPcm16Wav(a, pcm_b, 44100);

    const als =
        \\<Ableton MajorVersion="4" MinorVersion="9.0_305" Creator="Ableton Live 9.1.1">
        \\  <LiveSet>
        \\    <Tracks>
        \\      <MidiTrack>
        \\        <DrumGroupDevice><Branches>
        \\          <DrumBranch>
        \\            <InstrumentGroupDevice><Branches>
        \\              <InstrumentBranch>
        \\                <OriginalSimpler>
        \\                  <On><Manual Value="true" /></On>
        \\                  <MultiSamplePart>
        \\                    <SampleStart Value="200" /><SampleEnd Value="500" />
        \\                    <SampleRef><DefaultDuration Value="1000" /><DefaultSampleRate Value="44100" /><FileRef><Name Value="long.wav" /></FileRef></SampleRef>
        \\                  </MultiSamplePart>
        \\                </OriginalSimpler>
        \\                <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\              </InstrumentBranch>
        \\              <InstrumentBranch>
        \\                <OriginalSimpler>
        \\                  <On><Manual Value="true" /></On>
        \\                  <MultiSamplePart>
        \\                    <SampleStart Value="0" /><SampleEnd Value="400" />
        \\                    <SampleRef><DefaultDuration Value="400" /><DefaultSampleRate Value="44100" /><FileRef><Name Value="layer.wav" /></FileRef></SampleRef>
        \\                  </MultiSamplePart>
        \\                </OriginalSimpler>
        \\                <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\              </InstrumentBranch>
        \\            </Branches></InstrumentGroupDevice>
        \\            <BranchInfo><ReceivingNote Value="92" /></BranchInfo>
        \\          </DrumBranch>
        \\        </Branches></DrumGroupDevice>
        \\      </MidiTrack>
        \\      <MidiTrack>
        \\        <MidiOutputRouting><Target Value="MidiOut/External.Dev:Launchpad S/0" /></MidiOutputRouting>
        \\        <MidiEffectGroupDevice><Branches>
        \\          <MidiEffectBranch>
        \\            <DeviceChain><MidiToMidiDeviceChain><Devices>
        \\              <MidiVelocity><On><Manual Value="true" /></On><Mode><Manual Value="0" /></Mode><Operation><Manual Value="2" /></Operation><MaxOut><Manual Value="75" /></MaxOut></MidiVelocity>
        \\            </Devices></MidiToMidiDeviceChain></DeviceChain>
        \\            <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\            <ZoneSettings><KeyRange><Min Value="36" /><Max Value="36" /></KeyRange></ZoneSettings>
        \\          </MidiEffectBranch>
        \\        </Branches></MidiEffectGroupDevice>
        \\      </MidiTrack>
        \\    </Tracks>
        \\  </LiveSet>
        \\</Ableton>
    ;

    const files = [_]VirtualFile{
        .{ .rel_path = "Hello9.als", .bytes = als },
        .{ .rel_path = "Samples/long.wav", .bytes = wav_a },
        .{ .rel_path = "Samples/layer.wav", .bytes = wav_b },
    };

    const proj = try buildProject(a, &files, "Fallback");
    // Trimmed long.wav (300 frames) + layer.wav (400 frames) mixed into 1 single layered WAV entry on pad (7,0)
    try std.testing.expectEqual(@as(usize, 1), proj.sound_cells[7 * 8 + 0].len);
    const mixed_id = proj.sound_cells[7 * 8 + 0][0].sample_id;
    const mixed_wav = parseWav(proj.raw_sounds[mixed_id].bytes).?;
    try std.testing.expectEqual(@as(u64, 400), mixed_wav.total_frames);

    // Launchpad S velocity 75 (0x4B -> R=3,G=0) converted to RGB velocity 5 (Bright Red)
    try std.testing.expectEqual(@as(usize, 1), proj.led_cells[7 * 8 + 0].len);
    try std.testing.expectEqual(@as(u8, 5), proj.led_cells[7 * 8 + 0][0][0].pad_on.velocity);

    // Pure-Zig ZIP buffer export
    const res = try convertFilesToUniPackZipBuffer(std.testing.allocator, &files, "Fallback");
    defer {
        std.testing.allocator.free(res.title);
        std.testing.allocator.free(res.zip);
    }
    try std.testing.expectEqualStrings("Hello9", res.title);
    try std.testing.expect(res.zip.len > 64);
    try std.testing.expectEqualStrings("PK\x03\x04", res.zip[0..4]);

    // Disjoint KeyRange nested InstrumentBranches (MidiRandom multi-press) stay sequential, NOT mixed
    const seq_als =
        \\<Ableton MajorVersion="5">
        \\  <LiveSet><Tracks><MidiTrack>
        \\    <DrumGroupDevice><Branches>
        \\      <DrumBranch>
        \\        <InstrumentGroupDevice><Branches>
        \\          <InstrumentBranch>
        \\            <BranchSelectorRange><Min Value="1" /><Max Value="1" /></BranchSelectorRange>
        \\            <ZoneSettings><KeyRange><Min Value="0" /><Max Value="127" /></KeyRange></ZoneSettings>
        \\            <InstrumentGroupDevice><Branches>
        \\              <InstrumentBranch>
        \\                <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\                <ZoneSettings><KeyRange><Min Value="60" /><Max Value="60" /></KeyRange></ZoneSettings>
        \\                <OriginalSimpler><On><Manual Value="true" /></On><SampleRef><FileRef><Name Value="long.wav" /></FileRef></SampleRef></OriginalSimpler>
        \\              </InstrumentBranch>
        \\              <InstrumentBranch>
        \\                <BranchSelectorRange><Min Value="0" /><Max Value="0" /></BranchSelectorRange>
        \\                <ZoneSettings><KeyRange><Min Value="61" /><Max Value="61" /></KeyRange></ZoneSettings>
        \\                <OriginalSimpler><On><Manual Value="true" /></On><SampleRef><FileRef><Name Value="layer.wav" /></FileRef></SampleRef></OriginalSimpler>
        \\              </InstrumentBranch>
        \\            </Branches></InstrumentGroupDevice>
        \\          </InstrumentBranch>
        \\        </Branches></InstrumentGroupDevice>
        \\        <BranchInfo><ReceivingNote Value="92" /></BranchInfo>
        \\      </DrumBranch>
        \\    </Branches></DrumGroupDevice>
        \\  </MidiTrack></Tracks></LiveSet>
        \\</Ableton>
    ;
    const seq_files = [_]VirtualFile{
        .{ .rel_path = "Seq.als", .bytes = seq_als },
        .{ .rel_path = "Samples/long.wav", .bytes = wav_a },
        .{ .rel_path = "Samples/layer.wav", .bytes = wav_b },
    };
    const seq_proj = try buildProject(a, &seq_files, "Seq");
    // Placed in chain 1 (outer sel 1..1 preserved despite inner sel 0..0) as 2 separate sequential entries
    try std.testing.expectEqual(@as(usize, 0), seq_proj.sound_cells[7 * 8 + 0].len);
    try std.testing.expectEqual(@as(usize, 2), seq_proj.sound_cells[64 + 7 * 8 + 0].len);
}
