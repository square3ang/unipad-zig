//! Cross-platform MIDI I/O backend: ALSA Sequencer on Linux, CoreMIDI on macOS, WinMM on Windows.
const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");
const driver = @import("driver.zig");

pub const PortInfo = struct {
    id: u32, // Linux: (client << 16) | port; macOS/Win: endpoint index
    name: []const u8,
    can_read: bool,
    can_write: bool,
    port_index: u8 = 0,
    vid: u16 = 0,
    pid: u16 = 0,
    detected: ?driver.Model = null,
};

pub const Midi = struct {
    gpa: std.mem.Allocator,
    model: driver.Model = .launchpad_pro_mk3,
    auto_model: bool = true,
    connected_in: ?u32 = null,
    connected_out: ?u32 = null,
    connected_name: [128]u8 = @splat(0),
    connected_name_len: usize = 0,

    // Linux ALSA Sequencer handles
    seq: if (builtin.os.tag == .linux) ?*c.snd_seq_t else void = if (builtin.os.tag == .linux) null else {},
    seq_port: if (builtin.os.tag == .linux) c_int else void = if (builtin.os.tag == .linux) -1 else {},
    enc: if (builtin.os.tag == .linux) ?*c.snd_midi_event_t else void = if (builtin.os.tag == .linux) null else {},
    dec: if (builtin.os.tag == .linux) ?*c.snd_midi_event_t else void = if (builtin.os.tag == .linux) null else {},
    // Non-Linux handle
    plat: if (builtin.os.tag != .linux) ?*c.MidiPlat else void = if (builtin.os.tag != .linux) null else {},

    pub fn init(gpa: std.mem.Allocator) Midi {
        var m: Midi = .{ .gpa = gpa };
        if (builtin.os.tag == .linux) {
            var seq: ?*c.snd_seq_t = null;
            if (c.snd_seq_open(&seq, "default", c.SND_SEQ_OPEN_DUPLEX, c.SND_SEQ_NONBLOCK) == 0 and seq != null) {
                _ = c.snd_seq_set_client_name(seq, "unipad-zig");
                const port = c.snd_seq_create_simple_port(
                    seq,
                    "Launchpad I/O",
                    c.SND_SEQ_PORT_CAP_READ | c.SND_SEQ_PORT_CAP_WRITE | c.SND_SEQ_PORT_CAP_SUBS_READ | c.SND_SEQ_PORT_CAP_SUBS_WRITE,
                    c.SND_SEQ_PORT_TYPE_MIDI_GENERIC | c.SND_SEQ_PORT_TYPE_APPLICATION,
                );
                if (port >= 0) {
                    var enc: ?*c.snd_midi_event_t = null;
                    var dec: ?*c.snd_midi_event_t = null;
                    _ = c.snd_midi_event_new(256, &enc);
                    _ = c.snd_midi_event_new(256, &dec);
                    if (enc != null) c.snd_midi_event_no_status(enc, 1);
                    m.seq = seq;
                    m.seq_port = port;
                    m.enc = enc;
                    m.dec = dec;
                } else {
                    _ = c.snd_seq_close(seq);
                }
            }
        } else {
            m.plat = c.midi_plat_create();
        }
        return m;
    }

    pub fn deinit(m: *Midi) void {
        m.disconnect();
        if (builtin.os.tag == .linux) {
            if (m.enc) |e| c.snd_midi_event_free(e);
            if (m.dec) |d| c.snd_midi_event_free(d);
            if (m.seq) |s| _ = c.snd_seq_close(s);
            m.enc = null;
            m.dec = null;
            m.seq = null;
        } else {
            if (m.plat) |p| c.midi_plat_destroy(p);
            m.plat = null;
        }
    }

    pub fn connectedLabel(m: *const Midi) []const u8 {
        return m.connected_name[0..m.connected_name_len];
    }

    pub fn listPorts(m: *const Midi, a: std.mem.Allocator) []PortInfo {
        var out: std.ArrayList(PortInfo) = .empty;
        if (builtin.os.tag == .linux) {
            const seq = m.seq orelse return &.{};
            const self_client = c.snd_seq_client_id(seq);

            var cinfo: ?*c.snd_seq_client_info_t = null;
            var pinfo: ?*c.snd_seq_port_info_t = null;
            if (c.snd_seq_client_info_malloc(&cinfo) < 0) return &.{};
            defer c.snd_seq_client_info_free(cinfo);
            if (c.snd_seq_port_info_malloc(&pinfo) < 0) return &.{};
            defer c.snd_seq_port_info_free(pinfo);

            c.snd_seq_client_info_set_client(cinfo, -1);
            while (c.snd_seq_query_next_client(seq, cinfo) >= 0) {
                const cid = c.snd_seq_client_info_get_client(cinfo);
                if (cid == 0 or cid == self_client) continue;
                const cname = std.mem.span(c.snd_seq_client_info_get_name(cinfo));
                const card = c.snd_seq_client_info_get_card(cinfo);
                var usb_info: UsbInfo = .{};
                if (card >= 0) readLinuxUsbInfo(card, &usb_info);

                c.snd_seq_port_info_set_client(pinfo, cid);
                c.snd_seq_port_info_set_port(pinfo, -1);
                while (c.snd_seq_query_next_port(seq, pinfo) >= 0) {
                    const caps = c.snd_seq_port_info_get_capability(pinfo);
                    if ((caps & c.SND_SEQ_PORT_CAP_NO_EXPORT) != 0) continue;
                    const can_read = (caps & (c.SND_SEQ_PORT_CAP_READ | c.SND_SEQ_PORT_CAP_SUBS_READ)) == (c.SND_SEQ_PORT_CAP_READ | c.SND_SEQ_PORT_CAP_SUBS_READ);
                    const can_write = (caps & (c.SND_SEQ_PORT_CAP_WRITE | c.SND_SEQ_PORT_CAP_SUBS_WRITE)) == (c.SND_SEQ_PORT_CAP_WRITE | c.SND_SEQ_PORT_CAP_SUBS_WRITE);
                    if (!can_read and !can_write) continue;
                    const pid_num = c.snd_seq_port_info_get_port(pinfo);
                    const pname = std.mem.span(c.snd_seq_port_info_get_name(pinfo));
                    const full_name = std.fmt.allocPrint(a, "{s}: {s}", .{ cname, pname }) catch continue;
                    const det = driver.detectModel(full_name, usb_info.vid, usb_info.pid, usb_info.serialSlice());
                    out.append(a, .{
                        .id = (@as(u32, @intCast(cid)) << 16) | @as(u32, @intCast(pid_num)),
                        .name = full_name,
                        .can_read = can_read,
                        .can_write = can_write,
                        .port_index = @intCast(@min(pid_num, 255)),
                        .vid = usb_info.vid,
                        .pid = usb_info.pid,
                        .detected = det,
                    }) catch break;
                }
            }
        } else {
            const plat = m.plat orelse return &.{};
            const in_count = c.midi_plat_input_count(plat);
            const out_count = c.midi_plat_output_count(plat);
            var name_buf: [256]u8 = undefined;
            var i: u32 = 0;
            while (i < in_count) : (i += 1) {
                const len = c.midi_plat_input_name(plat, i, &name_buf, name_buf.len);
                if (len <= 0) continue;
                const nm = a.dupe(u8, name_buf[0..@intCast(len)]) catch continue;
                out.append(a, .{
                    .id = i,
                    .name = nm,
                    .can_read = true,
                    .can_write = false,
                    .detected = driver.detectModel(nm, 0, 0, ""),
                }) catch break;
            }
            i = 0;
            while (i < out_count) : (i += 1) {
                const len = c.midi_plat_output_name(plat, i, &name_buf, name_buf.len);
                if (len <= 0) continue;
                const nm = a.dupe(u8, name_buf[0..@intCast(len)]) catch continue;
                out.append(a, .{
                    .id = 0x80000000 | i,
                    .name = nm,
                    .can_read = false,
                    .can_write = true,
                    .detected = driver.detectModel(nm, 0, 0, ""),
                }) catch break;
            }
        }
        return out.items;
    }

    /// Scans ports and automatically connects to the first detected Launchpad (picking its preferred port).
    pub fn autoConnect(m: *Midi, a: std.mem.Allocator) bool {
        const ports = m.listPorts(a);
        if (ports.len == 0) return false;
        var best_in: ?PortInfo = null;
        var best_out: ?PortInfo = null;
        var best_in_score: i32 = -1;
        var best_out_score: i32 = -1;
        for (ports) |p| {
            const det = p.detected orelse continue;
            const score = portPreferenceScore(det, p);
            if (p.can_read and score > best_in_score) {
                best_in = p;
                best_in_score = score;
            }
            if (p.can_write and score > best_out_score) {
                best_out = p;
                best_out_score = score;
            }
        }
        if (best_in == null and best_out == null) return false;
        const chosen_model = (best_in orelse best_out.?).detected.?;
        if (m.auto_model) m.model = chosen_model;
        m.connect(
            if (best_in) |p| p.id else null,
            if (best_out) |p| p.id else null,
            (best_in orelse best_out.?).name,
        );
        return true;
    }

    fn portPreferenceScore(model: driver.Model, p: PortInfo) i32 {
        var score: i32 = 1;
        if (p.port_index == model.preferredPortIndex()) score += 4;
        // On macOS/Windows multi-port Launchpads label DAW/DIN/MIDI ports by name.
        if (std.mem.indexOf(u8, p.name, "MIDI") != null and std.mem.indexOf(u8, p.name, "DAW") == null and std.mem.indexOf(u8, p.name, "DIN") == null) {
            score += 2;
        }
        return score;
    }

    pub fn connect(m: *Midi, in_id: ?u32, out_id: ?u32, label: []const u8) void {
        m.disconnect();
        const n = @min(label.len, m.connected_name.len);
        @memcpy(m.connected_name[0..n], label[0..n]);
        m.connected_name_len = n;

        if (builtin.os.tag == .linux) {
            const seq = m.seq orelse return;
            if (in_id) |id| {
                const cid: c_int = @intCast(id >> 16);
                const pid: c_int = @intCast(id & 0xFFFF);
                if (c.snd_seq_connect_from(seq, m.seq_port, cid, pid) >= 0) m.connected_in = id;
            }
            if (out_id) |id| {
                const cid: c_int = @intCast(id >> 16);
                const pid: c_int = @intCast(id & 0xFFFF);
                if (c.snd_seq_connect_to(seq, m.seq_port, cid, pid) >= 0) m.connected_out = id;
            }
        } else {
            const plat = m.plat orelse return;
            if (in_id) |id| {
                if (c.midi_plat_open_input(plat, id & 0x7FFFFFFF) != 0) m.connected_in = id;
            }
            if (out_id) |id| {
                if (c.midi_plat_open_output(plat, id & 0x7FFFFFFF) != 0) m.connected_out = id;
            }
        }
        if (m.connected_out != null) {
            m.sendInit();
            m.sendClearLed();
        }
    }

    pub fn disconnect(m: *Midi) void {
        if (builtin.os.tag == .linux) {
            if (m.seq) |seq| {
                if (m.connected_in) |id| _ = c.snd_seq_disconnect_from(seq, m.seq_port, @intCast(id >> 16), @intCast(id & 0xFFFF));
                if (m.connected_out) |id| _ = c.snd_seq_disconnect_to(seq, m.seq_port, @intCast(id >> 16), @intCast(id & 0xFFFF));
            }
        } else {
            if (m.plat) |plat| c.midi_plat_close(plat);
        }
        m.connected_in = null;
        m.connected_out = null;
        m.connected_name_len = 0;
    }

    pub fn isConnected(m: *const Midi) bool {
        return m.connected_in != null or m.connected_out != null;
    }

    pub fn sendInit(m: *Midi) void {
        for (m.model.initSysEx()) |sysex| {
            m.sendBytes(sysex);
        }
        m.flush();
    }

    pub fn sendPadLed(m: *Midi, row: u8, col: u8, velocity: u8) void {
        if (m.connected_out == null) return;
        if (driver.encodePadLed(m.model, row, col, velocity)) |msg| {
            m.sendBytes(msg.slice());
        }
    }

    pub fn sendRingLed(m: *Midi, idx: u8, velocity: u8) void {
        if (m.connected_out == null) return;
        if (driver.encodeRingLed(m.model, idx, velocity)) |msg| {
            m.sendBytes(msg.slice());
        }
    }

    pub fn sendClearLed(m: *Midi) void {
        if (m.connected_out == null) return;
        for (0..8) |r| {
            for (0..8) |col_i| {
                m.sendPadLed(@intCast(r), @intCast(col_i), 0);
            }
        }
        for (0..33) |i| {
            m.sendRingLed(@intCast(i), 0);
        }
        m.flush();
    }

    pub fn sendBytes(m: *Midi, bytes: []const u8) void {
        if (m.connected_out == null or bytes.len == 0) return;
        if (builtin.os.tag == .linux) {
            const seq = m.seq orelse return;
            const enc = m.enc orelse return;
            var ev: c.snd_seq_event_t = std.mem.zeroes(c.snd_seq_event_t);
            ev.source.port = @intCast(m.seq_port);
            ev.dest.client = c.SND_SEQ_ADDRESS_SUBSCRIBERS;
            ev.dest.port = c.SND_SEQ_ADDRESS_UNKNOWN;
            ev.queue = c.SND_SEQ_QUEUE_DIRECT;

            if (bytes[0] == 0xF0) {
                ev.type = c.SND_SEQ_EVENT_SYSEX;
                ev.flags = c.SND_SEQ_EVENT_LENGTH_VARIABLE;
                ev.data.ext.len = @intCast(bytes.len);
                ev.data.ext.ptr = @constCast(bytes.ptr);
                _ = c.snd_seq_event_output(seq, &ev);
            } else {
                c.snd_midi_event_reset_encode(enc);
                if (c.snd_midi_event_encode(enc, bytes.ptr, @intCast(bytes.len), &ev) > 0 and ev.type != c.SND_SEQ_EVENT_NONE) {
                    _ = c.snd_seq_event_output(seq, &ev);
                }
            }
        } else {
            const plat = m.plat orelse return;
            c.midi_plat_send(plat, bytes.ptr, @intCast(bytes.len));
        }
    }

    pub fn flush(m: *Midi) void {
        if (builtin.os.tag == .linux) {
            if (m.seq) |seq| _ = c.snd_seq_drain_output(seq);
        }
    }

    /// Polls pending incoming MIDI events into `out`, returning the slice written.
    pub fn poll(m: *Midi, out: []driver.InputEvent) []driver.InputEvent {
        if (m.connected_in == null) return out[0..0];
        var count: usize = 0;

        if (builtin.os.tag == .linux) {
            const seq = m.seq orelse return out[0..0];
            while (count < out.len) {
                var ev_ptr: ?*c.snd_seq_event_t = null;
                const r = c.snd_seq_event_input(seq, &ev_ptr);
                if (r < 0 or ev_ptr == null) break;
                const ev = ev_ptr.?;
                const decoded: ?driver.InputEvent = switch (ev.type) {
                    c.SND_SEQ_EVENT_NOTEON => driver.decodeInput(m.model, 0x90 | (ev.data.note.channel & 0x0F), ev.data.note.note, ev.data.note.velocity),
                    c.SND_SEQ_EVENT_NOTEOFF => driver.decodeInput(m.model, 0x80 | (ev.data.note.channel & 0x0F), ev.data.note.note, 0),
                    c.SND_SEQ_EVENT_CONTROLLER => driver.decodeInput(m.model, 0xB0 | (ev.data.control.channel & 0x0F), @intCast(ev.data.control.param & 0x7F), @intCast(ev.data.control.value & 0x7F)),
                    else => null,
                };
                if (decoded) |d| {
                    out[count] = d;
                    count += 1;
                }
            }
        } else {
            const plat = m.plat orelse return out[0..0];
            var msg: [3]u8 = undefined;
            while (count < out.len and c.midi_plat_poll(plat, &msg) != 0) {
                if (driver.decodeInput(m.model, msg[0], msg[1], msg[2])) |d| {
                    out[count] = d;
                    count += 1;
                }
            }
        }
        return out[0..count];
    }
};

const UsbInfo = struct {
    vid: u16 = 0,
    pid: u16 = 0,
    serial: [64]u8 = @splat(0),
    serial_len: usize = 0,

    fn serialSlice(u: *const UsbInfo) []const u8 {
        return u.serial[0..u.serial_len];
    }
};

fn readLinuxUsbInfo(card: c_int, out: *UsbInfo) void {
    if (builtin.os.tag != .linux) return;
    var path_buf: [256]u8 = undefined;
    const vid_p = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/sound/card{d}/device/../idVendor", .{card}, 0) catch return;
    if (readSysfsSmall(vid_p)) |s| out.vid = std.fmt.parseInt(u16, s.slice(), 16) catch 0;
    const pid_p = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/sound/card{d}/device/../idProduct", .{card}, 0) catch return;
    if (readSysfsSmall(pid_p)) |s| out.pid = std.fmt.parseInt(u16, s.slice(), 16) catch 0;
    const ser_p = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/sound/card{d}/device/../serial", .{card}, 0) catch return;
    if (readSysfsSmall(ser_p)) |s| {
        const sl = s.slice();
        const n = @min(sl.len, out.serial.len);
        @memcpy(out.serial[0..n], sl[0..n]);
        out.serial_len = n;
    }
}

const SmallBuf = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn slice(s: *const SmallBuf) []const u8 {
        return std.mem.trim(u8, s.buf[0..s.len], " \t\r\n");
    }
};

fn readSysfsSmall(path: [:0]const u8) ?SmallBuf {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer std.Io.Threaded.closeFd(fd);
    var res: SmallBuf = .{};
    const n = std.posix.read(fd, &res.buf) catch return null;
    res.len = n;
    return res;
}

test "midi backend initializes, lists ports, and cleans up cleanly" {
    var m = Midi.init(std.testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = m.listPorts(arena.allocator());
}
