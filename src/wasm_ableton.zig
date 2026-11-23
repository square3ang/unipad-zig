//! Freestanding WebAssembly entry point for the Ableton Live (.als / .zip) -> UniPack (.zip) converter.
//! Pure Zig (no libc, no libarchive, no SDL): includes a STORE+DEFLATE ZIP reader,
//! streams gzip .als XML via std.compress.flate, and writes a portable UniPack .zip buffer.
const std = @import("std");
const ableton = @import("unipack/ableton.zig");

const alloc = std.heap.wasm_allocator;

const OwnedFile = struct {
    rel_path: []u8,
    bytes: []u8,
};

var g_files: std.ArrayList(OwnedFile) = .empty;
var g_out_zip: []u8 = &.{};
var g_out_json: []u8 = &.{};
var g_last_err: []u8 = &.{};

fn setErr(msg: []const u8) void {
    if (g_last_err.len > 0) alloc.free(g_last_err);
    g_last_err = alloc.dupe(u8, msg) catch &.{};
}

fn clearOutputs() void {
    if (g_out_zip.len > 0) {
        alloc.free(g_out_zip);
        g_out_zip = &.{};
    }
    if (g_out_json.len > 0) {
        alloc.free(g_out_json);
        g_out_json = &.{};
    }
    if (g_last_err.len > 0) {
        alloc.free(g_last_err);
        g_last_err = &.{};
    }
}

export fn wasm_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const s = alloc.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn wasm_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    if (len == 0) return;
    alloc.free(p[0..len]);
}

export fn wasm_reset() void {
    for (g_files.items) |f| {
        alloc.free(f.rel_path);
        alloc.free(f.bytes);
    }
    g_files.clearAndFree(alloc);
    clearOutputs();
}

fn isRelevantProjectFile(path: []const u8) bool {
    if (path.len == 0 or path[path.len - 1] == '/') return false;
    if (std.mem.startsWith(u8, path, "__MACOSX/")) return false;
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    if (base.len == 0 or std.mem.startsWith(u8, base, "._")) return false;
    if (std.ascii.eqlIgnoreCase(base, ".ds_store")) return false;
    if (std.ascii.eqlIgnoreCase(base, "0save")) return true;
    const exts = [_][]const u8{ ".als", ".wav", ".mp3", ".ogg", ".flac", ".aif", ".aiff", ".mid", ".midi" };
    for (exts) |ext| {
        if (path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn normalizePath(raw: []const u8) ![]u8 {
    var s = raw;
    while (std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, "/")) {
        s = if (s[0] == '.') s[2..] else s[1..];
    }
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |ch, i| {
        out[i] = if (ch == '\\') '/' else ch;
    }
    return out;
}

fn addOwnedFile(raw_path: []const u8, bytes_owned: []u8) !void {
    const norm = try normalizePath(raw_path);
    errdefer alloc.free(norm);
    try g_files.append(alloc, .{ .rel_path = norm, .bytes = bytes_owned });
}

export fn wasm_add_file(path_ptr: [*]const u8, path_len: usize, data_ptr: [*]const u8, data_len: usize) i32 {
    const path = path_ptr[0..path_len];
    if (!isRelevantProjectFile(path)) return 0;
    const copy = alloc.dupe(u8, data_ptr[0..data_len]) catch {
        setErr("Out of memory while copying input file");
        return -1;
    };
    addOwnedFile(path, copy) catch {
        alloc.free(copy);
        setErr("Out of memory while registering input file");
        return -1;
    };
    return 1;
}

/// Pure-Zig ZIP extractor (STORE + DEFLATE) that filters and adds relevant Ableton project files.
/// Returns number of files added (>= 0), or -1 on error.
export fn wasm_add_zip(data_ptr: [*]const u8, data_len: usize) i32 {
    const data = data_ptr[0..data_len];
    const count = extractZipIntoFiles(data) catch |err| {
        setErr(@errorName(err));
        return -1;
    };
    return @intCast(@min(count, @as(usize, std.math.maxInt(i32))));
}

fn extractZipIntoFiles(data: []const u8) !usize {
    if (data.len < 22) return error.InvalidZip;

    // Locate End of Central Directory (0x06054b50) scanning backwards (up to 64KB comment)
    const min_eocd: usize = if (data.len > 65557) data.len - 65557 else 0;
    var eocd_pos: ?usize = null;
    var p: usize = data.len - 22;
    while (true) {
        if (std.mem.readInt(u32, data[p..][0..4], .little) == 0x06054b50) {
            const comment_len = std.mem.readInt(u16, data[p + 20 ..][0..2], .little);
            if (p + 22 + comment_len == data.len) {
                eocd_pos = p;
                break;
            }
        }
        if (p == min_eocd) break;
        p -= 1;
    }
    const eocd = eocd_pos orelse return error.InvalidZip;

    const total_entries: usize = std.mem.readInt(u16, data[eocd + 10 ..][0..2], .little);
    const cd_size: usize = std.mem.readInt(u32, data[eocd + 12 ..][0..4], .little);
    const cd_offset: usize = std.mem.readInt(u32, data[eocd + 16 ..][0..4], .little);
    if (cd_offset > data.len or cd_offset + cd_size > data.len) return error.InvalidZip;

    const window_buf = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window_buf);

    var added: usize = 0;
    var pos: usize = cd_offset;
    const cd_end: usize = cd_offset + cd_size;

    var entry_idx: usize = 0;
    while (entry_idx < total_entries and pos + 46 <= cd_end) : (entry_idx += 1) {
        if (std.mem.readInt(u32, data[pos..][0..4], .little) != 0x02014b50) return error.InvalidZip;
        const method = std.mem.readInt(u16, data[pos + 10 ..][0..2], .little);
        const comp_sz: usize = std.mem.readInt(u32, data[pos + 20 ..][0..4], .little);
        const uncomp_sz: usize = std.mem.readInt(u32, data[pos + 24 ..][0..4], .little);
        const name_len: usize = std.mem.readInt(u16, data[pos + 28 ..][0..2], .little);
        const extra_len: usize = std.mem.readInt(u16, data[pos + 30 ..][0..2], .little);
        const comment_len: usize = std.mem.readInt(u16, data[pos + 32 ..][0..2], .little);
        const local_off: usize = std.mem.readInt(u32, data[pos + 42 ..][0..4], .little);
        if (pos + 46 + name_len + extra_len + comment_len > cd_end) return error.InvalidZip;

        const name = data[pos + 46 .. pos + 46 + name_len];
        pos += 46 + name_len + extra_len + comment_len;

        if (!isRelevantProjectFile(name)) continue;
        if (local_off + 30 > data.len) return error.InvalidZip;
        if (std.mem.readInt(u32, data[local_off..][0..4], .little) != 0x04034b50) return error.InvalidZip;
        const l_name_len: usize = std.mem.readInt(u16, data[local_off + 26 ..][0..2], .little);
        const l_extra_len: usize = std.mem.readInt(u16, data[local_off + 28 ..][0..2], .little);
        const payload_start = local_off + 30 + l_name_len + l_extra_len;
        if (payload_start + comp_sz > data.len) return error.InvalidZip;
        const payload = data[payload_start .. payload_start + comp_sz];

        const out_bytes: []u8 = switch (method) {
            0 => try alloc.dupe(u8, payload),
            8 => blk: {
                var in_reader: std.Io.Reader = .fixed(payload);
                var decomp = std.compress.flate.Decompress.init(&in_reader, .raw, window_buf);
                var out_list: std.ArrayList(u8) = .empty;
                errdefer out_list.deinit(alloc);
                if (uncomp_sz > 0 and uncomp_sz <= 128 * 1024 * 1024) {
                    try out_list.ensureTotalCapacity(alloc, uncomp_sz);
                }
                var tmp: [16384]u8 = undefined;
                while (true) {
                    const n = decomp.reader.readSliceShort(&tmp) catch return error.ZipDecompressFailed;
                    if (n == 0) break;
                    try out_list.appendSlice(alloc, tmp[0..n]);
                }
                break :blk try out_list.toOwnedSlice(alloc);
            },
            else => continue,
        };
        errdefer alloc.free(out_bytes);
        try addOwnedFile(name, out_bytes);
        added += 1;
    }
    return added;
}

fn appendJsonEscaped(list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try list.print(alloc, "\\u{x:0>4}", .{ch}),
            else => try list.append(alloc, ch),
        }
    }
    try list.append(alloc, '"');
}

export fn wasm_convert(fallback_title_ptr: [*]const u8, fallback_title_len: usize) i32 {
    clearOutputs();
    if (g_files.items.len == 0) {
        setErr("No Ableton project files (.als / samples) found");
        return -1;
    }

    const vfiles = alloc.alloc(ableton.VirtualFile, g_files.items.len) catch {
        setErr("Out of memory");
        return -1;
    };
    defer alloc.free(vfiles);
    for (g_files.items, 0..) |f, i| {
        vfiles[i] = .{ .rel_path = f.rel_path, .bytes = f.bytes };
    }

    const fallback = fallback_title_ptr[0..fallback_title_len];
    const res = ableton.convertFilesToUniPackZipBuffer(alloc, vfiles, fallback) catch |err| {
        setErr(@errorName(err));
        return -1;
    };
    defer alloc.free(res.title);

    g_out_zip = res.zip;

    var jb: std.ArrayList(u8) = .empty;
    errdefer jb.deinit(alloc);
    jb.appendSlice(alloc, "{\"title\":") catch {
        setErr("Out of memory");
        return -1;
    };
    appendJsonEscaped(&jb, res.title) catch {
        setErr("Out of memory");
        return -1;
    };
    jb.print(
        alloc,
        ",\"chains\":{d},\"sounds\":{d},\"ledPads\":{d},\"ledEvents\":{d},\"autoEvents\":{d},\"zipBytes\":{d}}}",
        .{ res.summary.chains, res.summary.sounds, res.summary.led_pads, res.summary.led_events, res.summary.auto_events, g_out_zip.len },
    ) catch {
        setErr("Out of memory");
        return -1;
    };
    g_out_json = jb.toOwnedSlice(alloc) catch {
        setErr("Out of memory");
        return -1;
    };
    return 0;
}

export fn wasm_out_zip_ptr() ?[*]const u8 {
    return if (g_out_zip.len > 0) g_out_zip.ptr else null;
}
export fn wasm_out_zip_len() usize {
    return g_out_zip.len;
}
export fn wasm_out_json_ptr() ?[*]const u8 {
    return if (g_out_json.len > 0) g_out_json.ptr else null;
}
export fn wasm_out_json_len() usize {
    return g_out_json.len;
}
export fn wasm_last_error_ptr() ?[*]const u8 {
    return if (g_last_err.len > 0) g_last_err.ptr else null;
}
export fn wasm_last_error_len() usize {
    return g_last_err.len;
}
