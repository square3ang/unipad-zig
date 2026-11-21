//! UniPack loader and parser supporting both .zip/.uni archives and unpacked directories.
//! Follows official UniPad (unipad-android) and web-unipad specifications.
const std = @import("std");
const c = @import("c");
const decode = @import("../audio/decode.zig");
const palette = @import("palette.zig");

pub const max_grid = 64;
pub const max_chains = 24;
pub const round_led_count = 32;
pub const logo_led_index = 32;

pub const SoundEntry = struct {
    sample_id: u32,
    /// -1 = infinite loop while held (file `0`), 0 = play once (file `1` or omitted), N > 0 = N extra repeats.
    loop: i32,
    /// 0-based target chain, or null if no wormhole.
    wormhole: ?u8 = null,
};

pub const LedEvent = union(enum) {
    pad_on: struct { row: u8, col: u8, color: u32, velocity: u8 },
    pad_off: struct { row: u8, col: u8 },
    ring_on: struct { idx: u8, color: u32, velocity: u8 }, // 0..31 round, 32 logo
    ring_off: u8,
    delay: u32,
    chain: u8,
};

pub const LedAnimation = struct {
    events: []const LedEvent,
    /// 0 = infinite loop while held, >= 1 = finite iteration count.
    loop: u32,
};

pub const AutoPlayEvent = union(enum) {
    on: struct { row: u8, col: u8 },
    off: struct { row: u8, col: u8 },
    chain: u8,
    delay: u32,
};

pub const UniPack = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    title: []const u8 = "Untitled UniPack",
    producer: []const u8 = "",
    website: []const u8 = "",
    button_x: u8 = 8, // rows (top to bottom)
    button_y: u8 = 8, // cols (left to right)
    chain_count: u8 = 1,
    square_button: bool = true,

    /// Indexed by `cellIndex(chain, row, col)`.
    sound_table: [][]const SoundEntry = &.{},
    led_table: [][]const LedAnimation = &.{},
    auto_play: []const AutoPlayEvent = &.{},
    samples: []decode.Sample = &.{},

    sound_count: usize = 0,
    led_count: usize = 0,

    pub fn deinit(p: *UniPack) void {
        for (p.samples) |s| if (s.data.len > 0) p.gpa.free(s.data);
        if (p.samples.len > 0) p.gpa.free(p.samples);
        p.arena.deinit();
    }

    pub fn cellIndex(p: *const UniPack, chain: u8, row: u8, col: u8) ?usize {
        if (chain >= p.chain_count or row >= p.button_x or col >= p.button_y) return null;
        return (@as(usize, chain) * p.button_x + row) * p.button_y + col;
    }

    pub fn soundsAt(p: *const UniPack, chain: u8, row: u8, col: u8) []const SoundEntry {
        const idx = p.cellIndex(chain, row, col) orelse return &.{};
        if (idx >= p.sound_table.len) return &.{};
        return p.sound_table[idx];
    }

    pub fn ledsAt(p: *const UniPack, chain: u8, row: u8, col: u8) []const LedAnimation {
        const idx = p.cellIndex(chain, row, col) orelse return &.{};
        if (idx >= p.led_table.len) return &.{};
        return p.led_table[idx];
    }
};

const VirtualFile = struct {
    /// Forward-slash relative path within the pack root.
    rel_path: []const u8,
    bytes: []const u8,
};

/// Loads a UniPack from either a directory path or a .zip/.uni archive file.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, sample_rate: u32) !*UniPack {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.FileNotFound;
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const ta = tmp_arena.allocator();

    var files: std.ArrayList(VirtualFile) = .empty;
    if (stat.kind == .directory) {
        try collectDir(ta, io, path, "", &files);
    } else {
        try collectArchive(ta, path, &files);
    }
    stripCommonPrefix(ta, files.items);
    return parseFiles(gpa, files.items, sample_rate);
}

fn collectDir(a: std.mem.Allocator, io: std.Io, base: []const u8, prefix: []const u8, out: *std.ArrayList(VirtualFile)) !void {
    const full_dir = if (prefix.len == 0) base else try std.fs.path.join(a, &.{ base, prefix });
    var dir = try std.Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, "__MACOSX") or std.mem.startsWith(u8, e.name, ".")) continue;
        const rel = if (prefix.len == 0)
            try a.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        if (e.kind == .directory) {
            try collectDir(a, io, base, rel, out);
        } else if (e.kind == .file or e.kind == .sym_link) {
            const full = try std.fs.path.join(a, &.{ base, rel });
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(128 * 1024 * 1024)) catch continue;
            try out.append(a, .{ .rel_path = rel, .bytes = bytes });
        }
    }
}

fn collectArchive(a: std.mem.Allocator, path: []const u8, out: *std.ArrayList(VirtualFile)) !void {
    const arch = c.archive_read_new() orelse return error.ArchiveInitFailed;
    defer _ = c.archive_read_free(arch);
    _ = c.archive_read_support_format_all(arch);
    _ = c.archive_read_support_filter_all(arch);

    const path_z = try a.dupeSentinel(u8, path, 0);
    if (c.archive_read_open_filename(arch, path_z.ptr, 65536) != c.ARCHIVE_OK) return error.ArchiveOpenFailed;

    var entry: ?*c.archive_entry = null;
    while (c.archive_read_next_header(arch, &entry) == c.ARCHIVE_OK) {
        const e = entry orelse continue;
        const raw_name_c = c.archive_entry_pathname(e) orelse continue;
        const raw_name = std.mem.span(raw_name_c);
        if (raw_name.len == 0 or raw_name[raw_name.len - 1] == '/') continue;
        const ftype = c.archive_entry_filetype(e);
        if (ftype == 0o040000) continue; // AE_IFDIR

        // Normalize backslashes and strip leading "./" or "/"
        var norm = try a.dupe(u8, raw_name);
        for (norm) |*ch| if (ch.* == '\\') {
            ch.* = '/';
        };
        while (std.mem.startsWith(u8, norm, "./")) norm = norm[2..];
        while (std.mem.startsWith(u8, norm, "/")) norm = norm[1..];
        if (std.mem.startsWith(u8, norm, "__MACOSX/")) continue;

        var buf: std.ArrayList(u8) = .empty;
        var chunk: [32768]u8 = undefined;
        while (true) {
            const n = c.archive_read_data(arch, &chunk, chunk.len);
            if (n < 0) return error.ArchiveReadFailed;
            if (n == 0) break;
            try buf.appendSlice(a, chunk[0..@intCast(n)]);
            if (buf.items.len > 128 * 1024 * 1024) break;
        }
        try out.append(a, .{ .rel_path = norm, .bytes = buf.items });
    }
}

/// Strips a single top-level wrapper folder if all pack files live inside it (e.g. `PackName/info`).
fn stripCommonPrefix(a: std.mem.Allocator, files: []VirtualFile) void {
    _ = a;
    if (files.len == 0) return;
    // If root already has info or keySound, keep as-is.
    for (files) |f| {
        if (std.ascii.eqlIgnoreCase(f.rel_path, "info") or std.ascii.eqlIgnoreCase(f.rel_path, "keysound")) return;
    }
    const first_slash = std.mem.indexOfScalar(u8, files[0].rel_path, '/') orelse return;
    const prefix = files[0].rel_path[0 .. first_slash + 1];
    for (files) |f| {
        if (!std.mem.startsWith(u8, f.rel_path, prefix)) return;
    }
    for (files) |*f| f.rel_path = f.rel_path[prefix.len..];
}

pub fn parseFiles(gpa: std.mem.Allocator, files: []const VirtualFile, sample_rate: u32) !*UniPack {
    const pack = try gpa.create(UniPack);
    pack.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    errdefer {
        pack.deinit();
        gpa.destroy(pack);
    }
    const pa = pack.arena.allocator();

    var info_bytes: ?[]const u8 = null;
    var keysound_bytes: ?[]const u8 = null;
    var autoplay_bytes: ?[]const u8 = null;

    var sound_files = std.StringHashMapUnmanaged(VirtualFile).empty;
    defer sound_files.deinit(gpa);
    var led_files: std.ArrayList(VirtualFile) = .empty;
    defer led_files.deinit(gpa);

    for (files) |f| {
        if (std.ascii.eqlIgnoreCase(f.rel_path, "info")) {
            info_bytes = f.bytes;
        } else if (std.ascii.eqlIgnoreCase(f.rel_path, "keysound")) {
            keysound_bytes = f.bytes;
        } else if (std.ascii.eqlIgnoreCase(f.rel_path, "autoplay")) {
            autoplay_bytes = f.bytes;
        } else if (startsWithIgnoreCase(f.rel_path, "sounds/")) {
            const base = basenameOf(f.rel_path);
            if (base.len > 0) {
                const key = try lowerAlloc(pa, base);
                try sound_files.put(gpa, key, f);
            }
        } else if (startsWithIgnoreCase(f.rel_path, "keyled/")) {
            const base = basenameOf(f.rel_path);
            if (base.len > 0) try led_files.append(gpa, f);
        }
    }

    var has_info = false;
    if (info_bytes) |ib| {
        has_info = true;
        const txt = try decodeText(pa, ib);
        parseInfo(pa, pack, txt);
    } else {
        // Fallback when loading minimal web-unipad zips without `info`.
        pack.button_x = 8;
        pack.button_y = 8;
        pack.chain_count = 8;
    }

    if (pack.button_x == 0 or pack.button_x > max_grid) pack.button_x = 8;
    if (pack.button_y == 0 or pack.button_y > max_grid) pack.button_y = 8;
    if (pack.chain_count == 0 or pack.chain_count > max_chains) pack.chain_count = 8;

    const total_cells = @as(usize, pack.chain_count) * pack.button_x * pack.button_y;

    // 1. Parse keySound & decode referenced unique audio files
    var decoded_samples: std.ArrayList(decode.Sample) = .empty;
    errdefer {
        for (decoded_samples.items) |s| if (s.data.len > 0) gpa.free(s.data);
        decoded_samples.deinit(gpa);
    }
    var sample_map = std.StringHashMapUnmanaged(u32).empty;
    defer sample_map.deinit(gpa);

    const sound_lists = try gpa.alloc(std.ArrayList(SoundEntry), total_cells);
    defer {
        for (sound_lists) |*l| l.deinit(gpa);
        gpa.free(sound_lists);
    }
    @memset(sound_lists, .empty);

    if (keysound_bytes) |kb| {
        const txt = try decodeText(pa, kb);
        var line_it: LineIter = .{ .buf = txt };
        var tok_buf: [16][]const u8 = undefined;
        while (line_it.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            const n = splitTokens(line, &tok_buf);
            if (n < 4) continue;
            const c_raw = parsePackInt(tok_buf[0]) orelse continue;
            const x_raw = parsePackInt(tok_buf[1]) orelse continue;
            const y_raw = parsePackInt(tok_buf[2]) orelse continue;
            const fname = tok_buf[3];
            const loop_raw: i32 = if (n >= 5) (parsePackInt(tok_buf[4]) orelse 1) else 1;
            var wormhole: ?u8 = null;
            if (n >= 6) {
                if (parsePackInt(tok_buf[5])) |w_raw| {
                    const w0 = std.math.clamp(w_raw - 1, 0, @as(i32, pack.chain_count) - 1);
                    wormhole = @intCast(w0);
                }
            }
            if (!has_info and c_raw > pack.chain_count and c_raw <= max_chains) {
                // Keep within bounds for info-less packs
            }
            if (c_raw < 1 or c_raw > pack.chain_count) continue;
            if (x_raw < 1 or x_raw > pack.button_x) continue;
            if (y_raw < 1 or y_raw > pack.button_y) continue;

            const lookup = try lowerAlloc(pa, basenameOf(fname));
            const sid: u32 = if (sample_map.get(lookup)) |existing| existing else blk: {
                const vf = sound_files.get(lookup) orelse continue;
                const samp = decode.decode(gpa, vf.bytes, vf.rel_path, sample_rate) catch |err| {
                    std.log.warn("sound decode failed ({s}): {t}", .{ vf.rel_path, err });
                    continue;
                };
                const id: u32 = @intCast(decoded_samples.items.len);
                try decoded_samples.append(gpa, samp);
                try sample_map.put(gpa, lookup, id);
                break :blk id;
            };

            const cell = pack.cellIndex(@intCast(c_raw - 1), @intCast(x_raw - 1), @intCast(y_raw - 1)).?;
            try sound_lists[cell].append(gpa, .{
                .sample_id = sid,
                .loop = loop_raw - 1, // file 0 -> -1 (infinite hold), file 1 -> 0 (once), file 2 -> 1 extra repeat
                .wormhole = wormhole,
            });
            pack.sound_count += 1;
        }
    }

    pack.samples = try decoded_samples.toOwnedSlice(gpa);
    const sound_table = try pa.alloc([]const SoundEntry, total_cells);
    for (sound_lists, 0..) |l, i| {
        sound_table[i] = try pa.dupe(SoundEntry, l.items);
    }
    pack.sound_table = sound_table;

    // 2. Parse keyLed/ (sorted by lowercased basename)
    std.mem.sort(VirtualFile, led_files.items, {}, struct {
        fn lessThan(_: void, a: VirtualFile, b: VirtualFile) bool {
            return asciiLessIgnoreCase(basenameOf(a.rel_path), basenameOf(b.rel_path));
        }
    }.lessThan);

    const led_lists = try gpa.alloc(std.ArrayList(LedAnimation), total_cells);
    defer {
        for (led_lists) |*l| l.deinit(gpa);
        gpa.free(led_lists);
    }
    @memset(led_lists, .empty);

    var events_tmp: std.ArrayList(LedEvent) = .empty;
    defer events_tmp.deinit(gpa);

    for (led_files.items) |lf| {
        const base = trimLine(basenameOf(lf.rel_path));
        var name_toks: [8][]const u8 = undefined;
        const nn = splitTokens(base, &name_toks);
        if (nn < 3) continue;
        const c_raw = parsePackInt(name_toks[0]) orelse continue;
        const x_raw = parsePackInt(name_toks[1]) orelse continue;
        const y_raw = parsePackInt(name_toks[2]) orelse continue;
        const loop_raw: i32 = if (nn >= 4) (parsePackInt(name_toks[3]) orelse 1) else 1;
        if (c_raw < 1 or c_raw > pack.chain_count) continue;
        if (x_raw < 1 or x_raw > pack.button_x) continue;
        if (y_raw < 1 or y_raw > pack.button_y) continue;
        if (loop_raw < 0) continue;

        events_tmp.clearRetainingCapacity();
        const txt = try decodeText(pa, lf.bytes);
        var line_it: LineIter = .{ .buf = txt };
        var tok_buf: [12][]const u8 = undefined;
        while (line_it.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            const n = splitTokens(line, &tok_buf);
            if (n < 2) continue;
            const cmd = tok_buf[0];

            if (std.mem.eql(u8, cmd, "on") or std.mem.eql(u8, cmd, "o")) {
                const target = tok_buf[1];
                if (std.mem.eql(u8, target, "mc") or std.mem.eql(u8, target, "*")) {
                    if (n < 4 or n > 5) continue;
                    const idx_raw = parsePackInt(tok_buf[2]) orelse continue;
                    if (idx_raw < 1 or idx_raw > round_led_count) continue;
                    const cv = parseLedColor(tok_buf[3..n]) orelse continue;
                    try events_tmp.append(gpa, .{ .ring_on = .{ .idx = @intCast(idx_raw - 1), .color = cv.color, .velocity = cv.velocity } });
                } else if (std.mem.eql(u8, target, "l")) {
                    const color_slice = logoColorTokens(tok_buf[0..n]) orelse continue;
                    const cv = parseLedColor(color_slice) orelse continue;
                    try events_tmp.append(gpa, .{ .ring_on = .{ .idx = logo_led_index, .color = cv.color, .velocity = cv.velocity } });
                } else {
                    if (n < 4 or n > 5) continue;
                    const rx = parsePackInt(target) orelse continue;
                    const ry = parsePackInt(tok_buf[2]) orelse continue;
                    if (rx < 1 or rx > pack.button_x or ry < 1 or ry > pack.button_y) continue;
                    const cv = parseLedColor(tok_buf[3..n]) orelse continue;
                    try events_tmp.append(gpa, .{ .pad_on = .{
                        .row = @intCast(rx - 1),
                        .col = @intCast(ry - 1),
                        .color = cv.color,
                        .velocity = cv.velocity,
                    } });
                }
            } else if (std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "f")) {
                const target = tok_buf[1];
                if (std.mem.eql(u8, target, "mc") or std.mem.eql(u8, target, "*")) {
                    if (n < 3) continue;
                    const idx_raw = parsePackInt(tok_buf[2]) orelse continue;
                    if (idx_raw < 1 or idx_raw > round_led_count) continue;
                    try events_tmp.append(gpa, .{ .ring_off = @intCast(idx_raw - 1) });
                } else if (std.mem.eql(u8, target, "l")) {
                    try events_tmp.append(gpa, .{ .ring_off = logo_led_index });
                } else {
                    if (n < 3) continue;
                    const rx = parsePackInt(target) orelse continue;
                    const ry = parsePackInt(tok_buf[2]) orelse continue;
                    if (rx < 1 or rx > pack.button_x or ry < 1 or ry > pack.button_y) continue;
                    try events_tmp.append(gpa, .{ .pad_off = .{ .row = @intCast(rx - 1), .col = @intCast(ry - 1) } });
                }
            } else if (std.mem.eql(u8, cmd, "delay") or std.mem.eql(u8, cmd, "d")) {
                const ms = parsePackInt(tok_buf[1]) orelse continue;
                try events_tmp.append(gpa, .{ .delay = @intCast(@max(ms, 0)) });
            } else if (std.mem.eql(u8, cmd, "chain") or std.mem.eql(u8, cmd, "c")) {
                const ch = parsePackInt(tok_buf[1]) orelse continue;
                if (ch < 1 or ch > pack.chain_count) continue;
                try events_tmp.append(gpa, .{ .chain = @intCast(ch - 1) });
            }
        }

        const cell = pack.cellIndex(@intCast(c_raw - 1), @intCast(x_raw - 1), @intCast(y_raw - 1)).?;
        try led_lists[cell].append(gpa, .{
            .events = try pa.dupe(LedEvent, events_tmp.items),
            .loop = @intCast(loop_raw),
        });
        pack.led_count += 1;
    }

    const led_table = try pa.alloc([]const LedAnimation, total_cells);
    for (led_lists, 0..) |l, i| {
        led_table[i] = try pa.dupe(LedAnimation, l.items);
    }
    pack.led_table = led_table;

    // 3. Parse autoPlay
    if (autoplay_bytes) |ab| {
        const txt = try decodeText(pa, ab);
        var auto_list: std.ArrayList(AutoPlayEvent) = .empty;
        defer auto_list.deinit(gpa);

        // Track sound cursors so wormholes inject chain events exactly as UniPackFolder.kt does.
        var cursor_map = try gpa.alloc(usize, @as(usize, pack.button_x) * pack.button_y);
        defer gpa.free(cursor_map);
        @memset(cursor_map, 0);
        var curr_chain: u8 = 0;

        var line_it: LineIter = .{ .buf = txt };
        var tok_buf: [8][]const u8 = undefined;
        while (line_it.next()) |raw_line| {
            const line = trimLine(raw_line);
            if (line.len == 0) continue;
            const n = splitTokens(line, &tok_buf);
            if (n < 2) continue;
            const cmd = tok_buf[0];

            if (std.mem.eql(u8, cmd, "on") or std.mem.eql(u8, cmd, "o") or std.mem.eql(u8, cmd, "touch") or std.mem.eql(u8, cmd, "t")) {
                if (n < 3) continue;
                const rx = parsePackInt(tok_buf[1]) orelse continue;
                const ry = parsePackInt(tok_buf[2]) orelse continue;
                if (rx < 1 or rx > pack.button_x or ry < 1 or ry > pack.button_y) continue;
                const r: u8 = @intCast(rx - 1);
                const col: u8 = @intCast(ry - 1);
                try auto_list.append(gpa, .{ .on = .{ .row = r, .col = col } });
                if (std.mem.eql(u8, cmd, "touch") or std.mem.eql(u8, cmd, "t")) {
                    try auto_list.append(gpa, .{ .off = .{ .row = r, .col = col } });
                }
                const sounds = pack.soundsAt(curr_chain, r, col);
                const pad_idx = @as(usize, r) * pack.button_y + col;
                if (sounds.len > 0) {
                    const s = sounds[cursor_map[pad_idx] % sounds.len];
                    cursor_map[pad_idx] += 1;
                    if (s.wormhole) |w| {
                        curr_chain = w;
                        try auto_list.append(gpa, .{ .chain = w });
                        @memset(cursor_map, 0);
                    }
                }
            } else if (std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "f")) {
                if (n < 3) continue;
                const rx = parsePackInt(tok_buf[1]) orelse continue;
                const ry = parsePackInt(tok_buf[2]) orelse continue;
                if (rx < 1 or rx > pack.button_x or ry < 1 or ry > pack.button_y) continue;
                try auto_list.append(gpa, .{ .off = .{ .row = @intCast(rx - 1), .col = @intCast(ry - 1) } });
            } else if (std.mem.eql(u8, cmd, "chain") or std.mem.eql(u8, cmd, "c")) {
                const ch = parsePackInt(tok_buf[1]) orelse continue;
                if (ch < 1 or ch > pack.chain_count) continue;
                curr_chain = @intCast(ch - 1);
                try auto_list.append(gpa, .{ .chain = curr_chain });
                @memset(cursor_map, 0);
            } else if (std.mem.eql(u8, cmd, "delay") or std.mem.eql(u8, cmd, "d")) {
                const ms = parsePackInt(tok_buf[1]) orelse continue;
                try auto_list.append(gpa, .{ .delay = @intCast(@max(ms, 0)) });
            }
        }
        pack.auto_play = try pa.dupe(AutoPlayEvent, auto_list.items);
    }

    return pack;
}

fn parseInfo(pa: std.mem.Allocator, pack: *UniPack, txt: []const u8) void {
    var it: LineIter = .{ .buf = txt };
    while (it.next()) |raw| {
        const line = trimLine(raw);
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trimLine(line[0..eq]);
        const val = trimLine(line[eq + 1 ..]);
        if (std.mem.eql(u8, key, "title")) {
            pack.title = pa.dupe(u8, val) catch pack.title;
        } else if (std.mem.eql(u8, key, "producerName")) {
            pack.producer = pa.dupe(u8, val) catch pack.producer;
        } else if (std.mem.eql(u8, key, "website")) {
            pack.website = pa.dupe(u8, val) catch pack.website;
        } else if (std.mem.eql(u8, key, "buttonX")) {
            if (parsePackInt(val)) |v| if (v >= 1 and v <= max_grid) {
                pack.button_x = @intCast(v);
            };
        } else if (std.mem.eql(u8, key, "buttonY")) {
            if (parsePackInt(val)) |v| if (v >= 1 and v <= max_grid) {
                pack.button_y = @intCast(v);
            };
        } else if (std.mem.eql(u8, key, "chain")) {
            if (parsePackInt(val)) |v| if (v >= 1 and v <= max_chains) {
                pack.chain_count = @intCast(v);
            };
        } else if (std.mem.eql(u8, key, "squareButton")) {
            pack.square_button = std.mem.eql(u8, val, "true");
        }
    }
}

const ColorVel = struct { color: u32, velocity: u8 };

fn isAutoToken(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "auto") or std.mem.eql(u8, tok, "a");
}

fn logoColorTokens(toks: []const []const u8) ?[]const []const u8 {
    return switch (toks.len) {
        3 => toks[2..3],
        4 => if (isAutoToken(toks[2])) toks[2..4] else toks[3..4],
        5 => toks[3..5],
        else => null,
    };
}

fn parseLedColor(toks: []const []const u8) ?ColorVel {
    if (toks.len == 1) {
        const hex = parseRgbHex(toks[0]) orelse return null;
        return .{ .color = hex, .velocity = palette.nearestVelocity(hex) };
    } else if (toks.len == 2) {
        const vel_raw = parsePackInt(toks[1]) orelse return null;
        const vel: u8 = @intCast(std.math.clamp(vel_raw, 0, 127));
        if (isAutoToken(toks[0])) {
            return .{ .color = palette.argbOf(vel), .velocity = vel };
        }
        const hex = parseRgbHex(toks[0]) orelse return null;
        return .{ .color = hex, .velocity = vel };
    }
    return null;
}

fn parseRgbHex(tok: []const u8) ?u32 {
    if (tok.len == 0 or tok.len > 6) return null;
    const v = std.fmt.parseInt(u32, tok, 16) catch return null;
    return 0xFF000000 | v;
}

fn parsePackInt(tok: []const u8) ?i32 {
    if (tok.len == 0) return null;
    return std.fmt.parseInt(i32, tok, 10) catch null;
}

fn decodeText(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) {
        return bytes[3..];
    }
    if (bytes.len >= 2 and ((bytes[0] == 0xFF and bytes[1] == 0xFE) or (bytes[0] == 0xFE and bytes[1] == 0xFF))) {
        const le = bytes[0] == 0xFF;
        const payload = bytes[2..];
        const units = payload.len / 2;
        const u16s = try a.alloc(u16, units);
        for (0..units) |i| {
            u16s[i] = if (le)
                std.mem.readInt(u16, payload[i * 2 ..][0..2], .little)
            else
                std.mem.readInt(u16, payload[i * 2 ..][0..2], .big);
        }
        return std.unicode.utf16LeToUtf8Alloc(a, u16s) catch bytes[2..];
    }
    return bytes;
}

/// Splits text on `\r\n`, `\n`, or bare `\r` (classic Mac / Ableton M4L keyLED exports).
const LineIter = struct {
    buf: []const u8,
    pos: usize = 0,

    fn next(it: *LineIter) ?[]const u8 {
        if (it.pos >= it.buf.len) return null;
        const start = it.pos;
        while (it.pos < it.buf.len) : (it.pos += 1) {
            const ch = it.buf[it.pos];
            if (ch == '\r' or ch == '\n') {
                const line = it.buf[start..it.pos];
                it.pos += 1;
                if (ch == '\r' and it.pos < it.buf.len and it.buf[it.pos] == '\n') it.pos += 1;
                return line;
            }
        }
        return it.buf[start..it.pos];
    }
};

fn trimLine(s: []const u8) []const u8 {
    var out = s;
    if (std.mem.startsWith(u8, out, "\xEF\xBB\xBF")) out = out[3..];
    return std.mem.trim(u8, out, " \t\r\n");
}

fn isTokenSep(s: []const u8, i: usize) ?usize {
    const b = s[i];
    if (b == ' ' or b == '\t' or b == '\r' or b == '\n') return 1;
    // U+00A0 (NO-BREAK SPACE)
    if (i + 1 < s.len and b == 0xC2 and s[i + 1] == 0xA0) return 2;
    // U+3000 (IDEOGRAPHIC SPACE, common with Korean IME)
    if (i + 2 < s.len and b == 0xE3 and s[i + 1] == 0x80 and s[i + 2] == 0x80) return 3;
    return null;
}

fn splitTokens(line: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and count < out.len) {
        while (i < line.len) {
            if (isTokenSep(line, i)) |step| {
                i += step;
            } else break;
        }
        if (i >= line.len) break;
        const start = i;
        while (i < line.len) {
            if (isTokenSep(line, i) != null) break;
            i += 1;
        }
        out[count] = line[start..i];
        count += 1;
    }
    return count;
}

fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    if (hay.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

fn lowerAlloc(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    _ = std.ascii.lowerString(out, s);
    return out;
}

fn asciiLessIgnoreCase(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

test "parseFiles parses info, keySound, keyLed (pad/mc/logo/hex/auto), and autoPlay" {
    const info =
        \\title=Test Song
        \\producerName=Tester
        \\buttonX=8
        \\buttonY=8
        \\chain=2
        \\squareButton=true
    ;
    // Tiny valid 44-byte stereo 48kHz 16-bit PCM WAV with 1 frame
    var wav = [_]u8{
        'R', 'I', 'F', 'F', 40, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0, 1, 0, 2, 0,
        0x80, 0xBB, 0, 0, 0x00, 0xEE, 2, 0, 4, 0, 16, 0,
        'd', 'a', 't', 'a', 4, 0, 0, 0, 0, 0, 0, 0,
    };
    const keysound =
        \\1 1 1 kick.wav 1 2
        \\1 1 2 Loop.wav 0
    ;
    const led1 =
        \\o 1 1 auto 5
        \\o mc 9 ff0000
        \\o l a 45
        \\d 50
        \\f 1 1
        \\c 2
    ;
    const autoplay =
        \\o 1 1
        \\d 100
        \\f 1 1
        \\t 1 2
    ;
    const vfiles = [_]VirtualFile{
        .{ .rel_path = "info", .bytes = info },
        .{ .rel_path = "sounds/kick.wav", .bytes = &wav },
        .{ .rel_path = "Sounds/loop.wav", .bytes = &wav },
        .{ .rel_path = "keySound", .bytes = keysound },
        .{ .rel_path = "keyLed/1 1 1 1", .bytes = led1 },
        .{ .rel_path = "autoPlay", .bytes = autoplay },
    };
    const p = try parseFiles(std.testing.allocator, &vfiles, 48000);
    defer {
        p.deinit();
        std.testing.allocator.destroy(p);
    }

    try std.testing.expectEqualStrings("Test Song", p.title);
    try std.testing.expectEqual(@as(u8, 2), p.chain_count);
    try std.testing.expectEqual(@as(usize, 2), p.samples.len);

    const s00 = p.soundsAt(0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), s00.len);
    try std.testing.expectEqual(@as(i32, 0), s00[0].loop);
    try std.testing.expectEqual(@as(?u8, 1), s00[0].wormhole);

    const s01 = p.soundsAt(0, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), s01.len);
    try std.testing.expectEqual(@as(i32, -1), s01[0].loop);

    const leds = p.ledsAt(0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), leds.len);
    try std.testing.expectEqual(@as(usize, 6), leds[0].events.len);
    try std.testing.expectEqual(@as(u8, 5), leds[0].events[0].pad_on.velocity);
    try std.testing.expectEqual(@as(u8, 8), leds[0].events[1].ring_on.idx);
    try std.testing.expectEqual(@as(u8, 32), leds[0].events[2].ring_on.idx);
    try std.testing.expectEqual(@as(u8, 45), leds[0].events[2].ring_on.velocity);

    // autoPlay: on(0,0) -> wormhole chain(1) -> delay(100) -> off(0,0) -> on(0,1) -> off(0,1)
    try std.testing.expectEqual(@as(usize, 6), p.auto_play.len);
    try std.testing.expectEqual(@as(u8, 1), p.auto_play[1].chain);
}

test "stripCommonPrefix unwraps nested archive root folder" {
    var files = [_]VirtualFile{
        .{ .rel_path = "MySong/info", .bytes = "" },
        .{ .rel_path = "MySong/keySound", .bytes = "" },
        .{ .rel_path = "MySong/sounds/a.wav", .bytes = "" },
    };
    stripCommonPrefix(std.testing.allocator, &files);
    try std.testing.expectEqualStrings("info", files[0].rel_path);
    try std.testing.expectEqualStrings("sounds/a.wav", files[2].rel_path);
}

test "CR-only line endings parse in keyLed, keySound, autoPlay, and info" {
    const info = "title=CR Pack\rproducerName=Maker\rbuttonX=8\rbuttonY=8\rchain=1";
    const led = "o 5 4 a 3\rd 55\rf 5 4\ro 4 4 a 2\r";
    const ap = "o 7 8\rf 7 8\rdelay 100\ro 8 8\r";
    const vfiles = [_]VirtualFile{
        .{ .rel_path = "info", .bytes = info },
        .{ .rel_path = "keyLED/1 7 8 1", .bytes = led },
        .{ .rel_path = "autoPlay", .bytes = ap },
    };
    const p = try parseFiles(std.testing.allocator, &vfiles, 48000);
    defer {
        p.deinit();
        std.testing.allocator.destroy(p);
    }
    try std.testing.expectEqualStrings("CR Pack", p.title);
    const anims = p.ledsAt(0, 6, 7);
    try std.testing.expectEqual(@as(usize, 1), anims.len);
    try std.testing.expectEqual(@as(usize, 4), anims[0].events.len);
    try std.testing.expectEqual(@as(u8, 3), anims[0].events[0].pad_on.velocity);
    try std.testing.expectEqual(@as(u32, 55), anims[0].events[1].delay);
    try std.testing.expectEqual(@as(usize, 4), p.auto_play.len);
}
