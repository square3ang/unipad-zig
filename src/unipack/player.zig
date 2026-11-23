//! UniPack runtime player: multi-map Sound/LED runners, wormholes, AutoPlay, and Guide mode.
const std = @import("std");
const pack_mod = @import("pack.zig");
const palette = @import("palette.zig");
const engine_mod = @import("../audio/engine.zig");

const UniPack = pack_mod.UniPack;
const LedAnimation = pack_mod.LedAnimation;

pub const LedCell = struct {
    color: u32 = 0, // 0xAARRGGBB, 0 = off
    velocity: u8 = 0,
    owner_pad_row: u8 = 0,
    owner_pad_col: u8 = 0,
    owner_chain: u8 = 0,
    owned: bool = false,
};

pub const LedOutEvent = union(enum) {
    pad: struct { row: u8, col: u8, velocity: u8, color: u32 = 0 },
    ring: struct { idx: u8, velocity: u8, color: u32 = 0 }, // 0..31 round, 32 logo
    clear,
};

const AnimState = struct {
    anim: LedAnimation,
    pad_row: u8,
    pad_col: u8,
    chain: u8,
    idx: usize = 0,
    loop_done: u32 = 0,
    next_due_ms: f64,
    pass_start_ms: f64,
    playing: bool = true,
    is_held_loop: bool = false,
};

const PendingWormhole = struct {
    target_chain: u8,
    due_ms: f64,
};

const PracticeStep = struct {
    time_ms: f64,
    kind: enum(u8) { pad, chain },
    row: u8 = 0,
    col: u8 = 0,
    chain: u8 = 0,
    done: bool = false,
};

const step_group_threshold_ms: u32 = 50;
const practice_lead_ms: f64 = 1000.0;

pub const Player = struct {
    gpa: std.mem.Allocator,
    pack: ?*UniPack = null,
    engine: *engine_mod.Engine,

    current_chain: u8 = 0,
    led_enabled: bool = true,
    show_chain: bool = true,
    guide_mode: bool = false,
    speed_multiplier: f32 = 1.0,

    // Per-pad runtime state (indexed [row * max_grid + col])
    sound_cursor: [pack_mod.max_grid * pack_mod.max_grid]usize = @splat(0),
    led_cursor: [pack_mod.max_grid * pack_mod.max_grid]usize = @splat(0),
    held_voice: [pack_mod.max_grid * pack_mod.max_grid]u32 = @splat(0),
    pad_pressed: [pack_mod.max_grid * pack_mod.max_grid]bool = @splat(false),
    pad_leds: [pack_mod.max_grid * pack_mod.max_grid]LedCell = @splat(.{}),
    ring_leds: [pack_mod.logo_led_index + 1]LedCell = @splat(.{}),

    anims: std.ArrayList(AnimState) = .empty,
    wormholes: std.ArrayList(PendingWormhole) = .empty,
    out_events: std.ArrayList(LedOutEvent) = .empty,

    // AutoPlay, Practice Mode & simultaneous-chord Guide state
    auto_playing: bool = false,
    auto_idx: usize = 0,
    auto_next_ms: f64 = 0,
    practice_playing: bool = false,
    practice_song_ms: f64 = 0,
    practice_last_ms: f64 = 0,
    practice_cursor: usize = 0,
    practice_paused_chain: ?u8 = null,
    practice_steps: std.ArrayList(PracticeStep) = .empty,
    practice_pad_level: [pack_mod.max_grid * pack_mod.max_grid]f32 = @splat(0),
    guide_idx: usize = 0,
    guide_expected_chain: u8 = 0,
    guide_pads: [pack_mod.max_grid * pack_mod.max_grid]bool = @splat(false),
    guide_pending: usize = 0,
    guide_chain: ?u8 = null,
    prev_guide_pads: [pack_mod.max_grid * pack_mod.max_grid]u8 = @splat(0),
    prev_guide_chain: ?u8 = null,
    smooth_guide_rgb: bool = false, // True when hardware output uses FastLED 0x5F 6-bit RGB
    prev_guide_rgb: [pack_mod.max_grid * pack_mod.max_grid]u32 = @splat(0),
    prev_guide_chain_rgb: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, engine: *engine_mod.Engine) Player {
        return .{ .gpa = gpa, .engine = engine };
    }

    pub fn deinit(p: *Player) void {
        p.unload();
        p.anims.deinit(p.gpa);
        p.wormholes.deinit(p.gpa);
        p.out_events.deinit(p.gpa);
        p.practice_steps.deinit(p.gpa);
    }

    pub fn unload(p: *Player) void {
        p.stopAutoPlay();
        p.stopPractice();
        p.engine.setSamples(&.{});
        if (p.pack) |pk| {
            pk.deinit();
            p.gpa.destroy(pk);
            p.pack = null;
        }
        p.resetState();
    }

    pub fn loadPack(p: *Player, new_pack: *UniPack) void {
        p.unload();
        p.pack = new_pack;
        p.engine.setSamples(new_pack.samples);
        p.current_chain = 0;
        p.resetState();
        p.refreshChainLed();
        p.resetGuide(0);
    }

    fn resetState(p: *Player) void {
        @memset(&p.sound_cursor, 0);
        @memset(&p.led_cursor, 0);
        @memset(&p.held_voice, 0);
        @memset(&p.pad_pressed, false);
        @memset(&p.pad_leds, .{});
        @memset(&p.ring_leds, .{});
        p.anims.clearRetainingCapacity();
        p.wormholes.clearRetainingCapacity();
        p.out_events.append(p.gpa, .clear) catch {};
    }

    pub fn setChain(p: *Player, chain: u8) void {
        const pk = p.pack orelse return;
        const clamped: u8 = @min(chain, pk.chain_count -| 1);
        const prev = p.current_chain;
        p.current_chain = clamped;
        @memset(&p.sound_cursor, 0);
        @memset(&p.led_cursor, 0);
        p.wormholes.clearRetainingCapacity();
        if (prev != clamped) {
            p.clearChainIndicator(prev);
        }
        p.refreshChainLed();
        if (p.practice_playing) {
            if (p.practice_paused_chain) |target_ch| {
                if (target_ch == clamped) {
                    while (p.practice_cursor < p.practice_steps.items.len) {
                        const st = &p.practice_steps.items[p.practice_cursor];
                        if (st.done) {
                            p.practice_cursor += 1;
                            continue;
                        }
                        if (st.kind == .chain and st.chain == clamped) {
                            st.done = true;
                            p.practice_cursor += 1;
                            continue;
                        }
                        break;
                    }
                    p.practice_paused_chain = null;
                    // Pause at the first pad of the new chain (full bright) so user starts at their own pace.
                    if (p.practice_cursor < p.practice_steps.items.len) {
                        p.practice_song_ms = p.practice_steps.items[p.practice_cursor].time_ms;
                    }
                    p.advancePracticeState();
                    p.updatePracticeGuides();
                    p.syncGuideLeds();
                }
            }
        } else if (p.guide_mode and !p.auto_playing) {
            if (p.guide_chain) |gc| {
                if (gc == clamped) {
                    p.guide_chain = null;
                    p.scanNextGuideChord();
                }
            }
            p.syncGuideLeds();
        }
    }

    pub fn setGuideMode(p: *Player, on: bool) void {
        if (p.guide_mode == on) return;
        p.guide_mode = on;
        if (on) {
            p.resetGuide(if (p.auto_playing) p.auto_idx else 0);
        } else {
            p.clearGuideTargets();
            p.syncGuideLeds();
        }
    }

    pub fn setShowChain(p: *Player, show: bool) void {
        if (p.show_chain == show) return;
        p.show_chain = show;
        if (!show) {
            p.clearChainIndicator(p.current_chain);
        } else {
            p.refreshChainLed();
        }
    }

    pub fn clearLeds(p: *Player) void {
        p.anims.clearRetainingCapacity();
        @memset(&p.pad_leds, .{});
        @memset(&p.ring_leds, .{});
        @memset(&p.prev_guide_pads, 0);
        p.prev_guide_chain = null;
        @memset(&p.prev_guide_rgb, 0);
        p.prev_guide_chain_rgb = 0;
        p.out_events.append(p.gpa, .clear) catch {};
        p.refreshChainLed();
        p.syncGuideLeds();
    }

    pub fn stopAllSounds(p: *Player) void {
        p.engine.stopAll();
        @memset(&p.held_voice, 0);
        p.wormholes.clearRetainingCapacity();
    }

    pub fn pressPad(p: *Player, row: u8, col: u8, now_ms: f64, follow_wormhole: bool) void {
        const pk = p.pack orelse return;
        if (row >= pk.button_x or col >= pk.button_y) return;
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        p.pad_pressed[idx] = true;

        // 1. Trigger Sound
        const sounds = pk.soundsAt(p.current_chain, row, col);
        if (sounds.len > 0) {
            const cur = p.sound_cursor[idx] % sounds.len;
            const s = sounds[cur];
            p.sound_cursor[idx] = (cur + 1) % sounds.len;

            if (p.held_voice[idx] != 0) {
                p.engine.stopVoice(p.held_voice[idx]);
                p.held_voice[idx] = 0;
            }
            const key = p.engine.play(s.sample_id, s.loop, p.speed_multiplier);
            if (s.loop == -1) p.held_voice[idx] = key;

            if (follow_wormhole) {
                if (s.wormhole) |target| {
                    p.wormholes.append(p.gpa, .{
                        .target_chain = target,
                        .due_ms = now_ms + 100.0 / @as(f64, @floatCast(@max(p.speed_multiplier, 0.1))),
                    }) catch {};
                }
            }
        }

        // 2. Advance Practice Mode or simultaneous-chord Guide Mode when user plays a pending pad
        if (p.practice_playing and p.practice_paused_chain == null) {
            p.consumePracticePad(row, col, now_ms);
        } else if (p.guide_mode and !p.auto_playing) {
            if (p.guide_pads[idx]) {
                p.guide_pads[idx] = false;
                p.guide_pending -|= 1;
                if (p.guide_pending == 0 and p.guide_chain == null) {
                    p.scanNextGuideChord();
                }
            }
        }

        // 3. Trigger LED animation
        if (p.led_enabled) {
            const leds = pk.ledsAt(p.current_chain, row, col);
            if (leds.len > 0) {
                p.shutdownMatchingAnims(row, col, p.current_chain, true);

                const lcur = p.led_cursor[idx] % leds.len;
                const anim = leds[lcur];
                p.led_cursor[idx] = (lcur + 1) % leds.len;
                if (anim.events.len > 0) {
                    p.anims.append(p.gpa, .{
                        .anim = anim,
                        .pad_row = row,
                        .pad_col = col,
                        .chain = p.current_chain,
                        .next_due_ms = now_ms,
                        .pass_start_ms = now_ms,
                        .is_held_loop = anim.loop == 0,
                    }) catch {};
                    p.tickAnims(now_ms);
                }
            }
        }
        if (p.practice_playing) {
            p.updatePracticeGuides();
            p.syncGuideLeds();
        } else if (p.guide_mode) {
            p.syncGuideLeds();
        }
    }

    pub fn releasePad(p: *Player, row: u8, col: u8) void {
        const pk = p.pack orelse return;
        if (row >= pk.button_x or col >= pk.button_y) return;
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        p.pad_pressed[idx] = false;

        if (p.held_voice[idx] != 0) {
            p.engine.stopVoice(p.held_voice[idx]);
            p.held_voice[idx] = 0;
        }
        // End any held loop (loop == 0) animation owned by this pad
        p.shutdownMatchingAnims(row, col, 0, false);
    }

    pub fn startAutoPlay(p: *Player, now_ms: f64) void {
        const pk = p.pack orelse return;
        if (pk.auto_play.len == 0) return;
        p.stopPractice();
        p.stopAllSounds();
        p.clearLeds();
        p.setChain(0);
        p.auto_playing = true;
        p.auto_idx = 0;
        p.auto_next_ms = now_ms + 200.0;
    }

    pub fn stopAutoPlay(p: *Player) void {
        if (!p.auto_playing) return;
        p.auto_playing = false;
        p.stopAllSounds();
        for (0..pack_mod.max_grid * pack_mod.max_grid) |i| {
            if (p.pad_pressed[i]) {
                p.pad_pressed[i] = false;
                const r: u8 = @intCast(i / pack_mod.max_grid);
                const c_idx: u8 = @intCast(i % pack_mod.max_grid);
                p.shutdownMatchingAnims(r, c_idx, 0, false);
            }
        }
    }

    pub fn startPractice(p: *Player, now_ms: f64) void {
        const pk = p.pack orelse return;
        if (pk.auto_play.len == 0) return;
        p.stopAutoPlay();
        p.stopAllSounds();
        p.clearLeds();
        p.setChain(0);

        p.practice_steps.clearRetainingCapacity();
        var t_ms: f64 = 0;
        var cur_ch: u8 = 0;
        for (pk.auto_play) |ev| {
            switch (ev) {
                .on => |o| p.practice_steps.append(p.gpa, .{
                    .time_ms = t_ms,
                    .kind = .pad,
                    .row = o.row,
                    .col = o.col,
                    .chain = cur_ch,
                }) catch {},
                .chain => |ch| {
                    cur_ch = ch;
                    p.practice_steps.append(p.gpa, .{
                        .time_ms = t_ms,
                        .kind = .chain,
                        .chain = ch,
                    }) catch {};
                },
                .delay => |ms| t_ms += @floatFromInt(ms),
                .off => {},
            }
        }
        if (p.practice_steps.items.len == 0) return;

        p.practice_playing = true;
        p.practice_cursor = 0;
        p.practice_paused_chain = null;
        // Start ready on the first step (like Guide Mode), then pace upcoming pads from each press.
        p.practice_song_ms = p.practice_steps.items[0].time_ms;
        p.practice_last_ms = now_ms;
        @memset(&p.practice_pad_level, 0);
        p.advancePracticeState();
        p.updatePracticeGuides();
        p.syncGuideLeds();
    }

    pub fn stopPractice(p: *Player) void {
        if (!p.practice_playing) return;
        p.practice_playing = false;
        p.practice_paused_chain = null;
        @memset(&p.practice_pad_level, 0);
        p.syncGuideLeds();
    }

    pub fn practiceProgress(p: *const Player) f32 {
        if (p.practice_steps.items.len == 0) return 0;
        return @as(f32, @floatFromInt(p.practice_cursor)) / @as(f32, @floatFromInt(p.practice_steps.items.len));
    }

    /// Returns end index (exclusive) of the simultaneous chord starting at `start_idx`.
    fn practiceChordEndFrom(p: *const Player, start_idx: usize) usize {
        if (start_idx >= p.practice_steps.items.len) return start_idx;
        const first = p.practice_steps.items[start_idx];
        if (first.kind != .pad) return start_idx;
        var seen: [pack_mod.max_grid * pack_mod.max_grid]bool = @splat(false);
        var i = start_idx;
        while (i < p.practice_steps.items.len) : (i += 1) {
            const st = p.practice_steps.items[i];
            if (st.done) continue;
            if (st.kind == .chain) {
                if (st.chain != p.current_chain) break;
                continue;
            }
            if (st.time_ms - first.time_ms >= @as(f64, @floatFromInt(step_group_threshold_ms))) break;
            const pidx = @as(usize, st.row) * pack_mod.max_grid + st.col;
            if (seen[pidx]) break;
            seen[pidx] = true;
        }
        return i;
    }

    fn currentPracticeChordEnd(p: *const Player) usize {
        return p.practiceChordEndFrom(p.practice_cursor);
    }

    /// Advances practice_cursor past done steps and pauses automatically on a chain transition.
    fn advancePracticeState(p: *Player) void {
        while (p.practice_cursor < p.practice_steps.items.len) {
            const st = &p.practice_steps.items[p.practice_cursor];
            if (st.done) {
                p.practice_cursor += 1;
                continue;
            }
            if (st.kind == .chain) {
                if (st.chain == p.current_chain) {
                    st.done = true;
                    p.practice_cursor += 1;
                    continue;
                }
                p.practice_paused_chain = st.chain;
                return;
            }
            break;
        }
        if (p.practice_cursor >= p.practice_steps.items.len) {
            p.practice_playing = false;
            p.practice_paused_chain = null;
            @memset(&p.practice_pad_level, 0);
        }
    }

    fn consumePracticePad(p: *Player, row: u8, col: u8, now_ms: f64) void {
        const chord_end = p.currentPracticeChordEnd();
        var matched = false;
        var chord_time: f64 = p.practice_song_ms;
        var i = p.practice_cursor;
        while (i < chord_end) : (i += 1) {
            const st = &p.practice_steps.items[i];
            if (st.done or st.kind != .pad) continue;
            if (st.row == row and st.col == col) {
                st.done = true;
                chord_time = st.time_ms;
                matched = true;
                break;
            }
        }
        if (!matched) return;

        // Check if any pads remain in this chord
        var remaining = false;
        var j = p.practice_cursor;
        while (j < chord_end) : (j += 1) {
            const st = p.practice_steps.items[j];
            if (!st.done and st.kind == .pad) {
                remaining = true;
                break;
            }
        }
        if (!remaining) {
            // Anchor virtual clock to the completed chord so upcoming pads ramp in real-time from now_ms.
            p.practice_song_ms = chord_time;
            p.practice_last_ms = now_ms;
            p.advancePracticeState();
        }
    }

    fn tickPractice(p: *Player, now_ms: f64) void {
        if (!p.practice_playing) return;
        const dt = @max(0.0, now_ms - p.practice_last_ms);
        p.practice_last_ms = now_ms;

        p.advancePracticeState();
        if (!p.practice_playing) return;

        if (p.practice_paused_chain == null and p.practice_cursor < p.practice_steps.items.len) {
            const cur_target_ms = p.practice_steps.items[p.practice_cursor].time_ms;
            const speed: f64 = @floatCast(@max(p.speed_multiplier, 0.1));
            // Advance toward the current chord's target time, then wait there (never skip unpressed pads).
            p.practice_song_ms = @min(cur_target_ms, p.practice_song_ms + dt * speed);
        }
        p.updatePracticeGuides();
    }

    fn updatePracticeGuides(p: *Player) void {
        @memset(&p.practice_pad_level, 0);
        if (!p.practice_playing or p.practice_paused_chain != null) return;

        const ramp_ms: f64 = if (p.smooth_guide_rgb) 320.0 else 180.0;
        const ramp_floor: f64 = if (p.smooth_guide_rgb) 0.25 else 0.35;
        const chord_end = p.currentPracticeChordEnd();

        // 1. Current chord (press NOW -> 1.0 full white; approaching within ramp_ms -> smooth ramp; earlier -> 0.20 preview)
        var i = p.practice_cursor;
        while (i < chord_end) : (i += 1) {
            const st = p.practice_steps.items[i];
            if (st.done or st.kind != .pad) continue;
            const rem = st.time_ms - p.practice_song_ms;
            const prog: f32 = if (rem <= 0.0)
                1.0
            else if (rem <= ramp_ms)
                @floatCast(ramp_floor + (1.0 - ramp_floor) * (1.0 - rem / ramp_ms))
            else
                0.20;
            const pidx = @as(usize, st.row) * pack_mod.max_grid + st.col;
            if (prog > p.practice_pad_level[pidx]) p.practice_pad_level[pidx] = prog;
        }

        // 2. Preview ONLY the single next chord (within practice_lead_ms, before any chain switch) as dim preview (0.10)
        var next_start = chord_end;
        while (next_start < p.practice_steps.items.len) : (next_start += 1) {
            const st = p.practice_steps.items[next_start];
            if (st.done) continue;
            if (st.kind == .chain) {
                if (st.chain != p.current_chain) return;
                continue;
            }
            break;
        }
        if (next_start < p.practice_steps.items.len) {
            const next_st = p.practice_steps.items[next_start];
            if (next_st.time_ms - p.practice_song_ms <= practice_lead_ms) {
                const next_end = p.practiceChordEndFrom(next_start);
                var k = next_start;
                while (k < next_end) : (k += 1) {
                    const st = p.practice_steps.items[k];
                    if (st.done or st.kind != .pad) continue;
                    const pidx = @as(usize, st.row) * pack_mod.max_grid + st.col;
                    if (p.practice_pad_level[pidx] < 0.10) p.practice_pad_level[pidx] = 0.10;
                }
            }
        }
    }

    pub fn autoProgress(p: *const Player) f32 {
        const pk = p.pack orelse return 0;
        if (pk.auto_play.len == 0) return 0;
        return @as(f32, @floatFromInt(p.auto_idx)) / @as(f32, @floatFromInt(pk.auto_play.len));
    }

    pub fn tick(p: *Player, now_ms: f64) void {
        // 1. Apply due wormholes
        var wi: usize = 0;
        while (wi < p.wormholes.items.len) {
            if (p.wormholes.items[wi].due_ms <= now_ms) {
                const target = p.wormholes.items[wi].target_chain;
                _ = p.wormholes.orderedRemove(wi);
                p.setChain(target);
            } else {
                wi += 1;
            }
        }

        // 2. Step AutoPlay or Practice Mode
        if (p.auto_playing) {
            if (p.pack) |pk| {
                const speed: f64 = @floatCast(@max(p.speed_multiplier, 0.1));
                var steps: usize = 0;
                while (p.auto_playing and p.auto_idx < pk.auto_play.len and p.auto_next_ms <= now_ms and steps < 256) : (steps += 1) {
                    const ev = pk.auto_play[p.auto_idx];
                    p.auto_idx += 1;
                    switch (ev) {
                        .on => |o| p.pressPad(o.row, o.col, p.auto_next_ms, false),
                        .off => |f| p.releasePad(f.row, f.col),
                        .chain => |ch| p.setChain(ch),
                        .delay => |ms| p.auto_next_ms += @as(f64, @floatFromInt(ms)) / speed,
                    }
                }
                if (p.auto_idx >= pk.auto_play.len) {
                    p.auto_playing = false;
                }
            }
        } else if (p.practice_playing) {
            p.tickPractice(now_ms);
        }

        // 3. Advance LED animations
        p.tickAnims(now_ms);
        if (p.practice_playing) {
            p.syncGuideLeds();
        } else if (p.guide_mode) {
            if (p.auto_playing) p.previewAutoGuideChord();
            p.syncGuideLeds();
        }
    }

    fn tickAnims(p: *Player, now_ms: f64) void {
        const speed: f64 = @floatCast(@max(p.speed_multiplier, 0.1));
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            // Find earliest due animation so interleaved animations resolve in pack time order.
            var best: ?usize = null;
            for (p.anims.items, 0..) |a, i| {
                if (!a.playing or a.next_due_ms > now_ms) continue;
                if (best == null or a.next_due_ms < p.anims.items[best.?].next_due_ms) {
                    best = i;
                }
            }
            const idx = best orelse break;
            const st = &p.anims.items[idx];
            const ev = st.anim.events[st.idx];
            switch (ev) {
                .pad_on => |on| p.setPadLed(on.row, on.col, on.color, on.velocity, st.pad_row, st.pad_col, st.chain),
                .pad_off => |off| p.clearPadLedIfOwned(off.row, off.col, st.pad_row, st.pad_col, st.chain),
                .ring_on => |on| p.setRingLed(on.idx, on.color, on.velocity, st.pad_row, st.pad_col, st.chain),
                .ring_off => |ridx| p.clearRingLedIfOwned(ridx, st.pad_row, st.pad_col, st.chain),
                .delay => |ms| st.next_due_ms += @as(f64, @floatFromInt(ms)) / speed,
                .chain => |ch| p.setChain(ch),
            }
            st.idx += 1;
            if (st.idx >= st.anim.events.len) {
                st.loop_done += 1;
                st.idx = 0;
                if (st.anim.loop != 0 and st.next_due_ms <= st.pass_start_ms) {
                    st.loop_done = st.anim.loop;
                }
                if (st.anim.loop == 0 and st.next_due_ms <= st.pass_start_ms) {
                    // Prevent infinite zero-delay loop lockup
                    st.next_due_ms = now_ms + 16.0;
                }
                st.pass_start_ms = st.next_due_ms;
                if (st.anim.loop != 0 and st.loop_done >= st.anim.loop) {
                    st.playing = false;
                }
            }
        }

        // Remove finished animations
        var i: usize = 0;
        while (i < p.anims.items.len) {
            if (!p.anims.items[i].playing) {
                _ = p.anims.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn shutdownMatchingAnims(p: *Player, row: u8, col: u8, chain: u8, include_same_chain: bool) void {
        var i: usize = 0;
        while (i < p.anims.items.len) {
            const a = p.anims.items[i];
            const match_held = a.is_held_loop and a.pad_row == row and a.pad_col == col;
            const match_same = include_same_chain and a.pad_row == row and a.pad_col == col and a.chain == chain;
            if (match_held or match_same) {
                p.turnOffOwnedBy(a.pad_row, a.pad_col, a.chain);
                _ = p.anims.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn turnOffOwnedBy(p: *Player, pad_row: u8, pad_col: u8, chain: u8) void {
        const pk = p.pack orelse return;
        for (0..pk.button_x) |r| {
            for (0..pk.button_y) |col_i| {
                p.clearPadLedIfOwned(@intCast(r), @intCast(col_i), pad_row, pad_col, chain);
            }
        }
        for (0..pack_mod.logo_led_index + 1) |ri| {
            p.clearRingLedIfOwned(@intCast(ri), pad_row, pad_col, chain);
        }
    }

    fn setPadLed(p: *Player, row: u8, col: u8, color: u32, velocity: u8, orow: u8, ocol: u8, ochain: u8) void {
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        p.pad_leds[idx] = .{
            .color = color,
            .velocity = velocity,
            .owner_pad_row = orow,
            .owner_pad_col = ocol,
            .owner_chain = ochain,
            .owned = true,
        };
        p.out_events.append(p.gpa, .{ .pad = .{ .row = row, .col = col, .velocity = velocity, .color = color } }) catch {};
    }

    fn clearPadLedIfOwned(p: *Player, row: u8, col: u8, orow: u8, ocol: u8, ochain: u8) void {
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        const cell = &p.pad_leds[idx];
        if (!cell.owned) return;
        if (cell.owner_pad_row == orow and cell.owner_pad_col == ocol and cell.owner_chain == ochain) {
            cell.* = .{};
            if (p.smooth_guide_rgb) {
                const gargb = p.guidePadFastLedArgb(row, col);
                p.out_events.append(p.gpa, .{ .pad = .{ .row = row, .col = col, .velocity = 0, .color = gargb } }) catch {};
            } else {
                const gvel = p.guidePadVelocity(row, col);
                p.out_events.append(p.gpa, .{ .pad = .{ .row = row, .col = col, .velocity = gvel, .color = palette.argbOf(gvel) } }) catch {};
            }
        }
    }

    fn setRingLed(p: *Player, idx: u8, color: u32, velocity: u8, orow: u8, ocol: u8, ochain: u8) void {
        if (idx > pack_mod.logo_led_index) return;
        p.ring_leds[idx] = .{
            .color = color,
            .velocity = velocity,
            .owner_pad_row = orow,
            .owner_pad_col = ocol,
            .owner_chain = ochain,
            .owned = true,
        };
        p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = velocity, .color = color } }) catch {};
    }

    fn clearRingLedIfOwned(p: *Player, idx: u8, orow: u8, ocol: u8, ochain: u8) void {
        if (idx > pack_mod.logo_led_index) return;
        const cell = &p.ring_leds[idx];
        if (!cell.owned) return;
        if (cell.owner_pad_row == orow and cell.owner_pad_col == ocol and cell.owner_chain == ochain) {
            cell.* = .{};
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 0, .color = 0 } }) catch {};
            if (p.show_chain and idx == p.current_chain + 8) p.refreshChainLed();
        }
    }

    fn clearChainIndicator(p: *Player, ch: u8) void {
        const idx = ch + 8;
        if (idx >= pack_mod.round_led_count) return;
        if (!p.ring_leds[idx].owned) {
            p.ring_leds[idx] = .{};
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 0, .color = 0 } }) catch {};
        }
    }

    pub fn refreshChainLed(p: *Player) void {
        if (!p.show_chain) return;
        const idx = p.current_chain + 8;
        if (idx >= pack_mod.round_led_count) return;
        if (!p.ring_leds[idx].owned) {
            p.ring_leds[idx] = .{ .color = palette.argbOf(3), .velocity = 3, .owned = false };
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 3, .color = palette.argbOf(3) } }) catch {};
        }
    }

    /// Re-emits current LED state (used when a hardware Launchpad newly connects).
    pub fn pushFullLedSync(p: *Player) void {
        p.out_events.append(p.gpa, .clear) catch {};
        const pk = p.pack orelse return;
        for (0..pk.button_x) |r| {
            for (0..pk.button_y) |c_idx| {
                const cell = p.pad_leds[r * pack_mod.max_grid + c_idx];
                if (cell.velocity != 0 or cell.color != 0) {
                    p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(c_idx), .velocity = cell.velocity, .color = cell.color } }) catch {};
                }
            }
        }
        for (0..pack_mod.logo_led_index + 1) |i| {
            const cell = p.ring_leds[i];
            if (cell.velocity != 0 or cell.color != 0) {
                p.out_events.append(p.gpa, .{ .ring = .{ .idx = @intCast(i), .velocity = cell.velocity, .color = cell.color } }) catch {};
            }
        }
        @memset(&p.prev_guide_pads, 0);
        p.prev_guide_chain = null;
        @memset(&p.prev_guide_rgb, 0);
        p.prev_guide_chain_rgb = 0;
        p.syncGuideLeds();
    }

    pub fn drainOutEvents(p: *Player) []const LedOutEvent {
        return p.out_events.items;
    }

    pub fn clearOutEvents(p: *Player) void {
        p.out_events.clearRetainingCapacity();
    }

    pub fn isGuidePad(p: *const Player, row: u8, col: u8) bool {
        return p.guidePadLevel(row, col) > 0.0;
    }

    pub fn guidePadLevel(p: *const Player, row: u8, col: u8) f32 {
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        if (p.practice_playing) return p.practice_pad_level[idx];
        if (p.guide_mode and p.guide_pads[idx]) return 1.0;
        return 0.0;
    }

    fn packRgb6(r6: u8, g6: u8, b6: u8) u32 {
        return 0xFF000000 | (@as(u32, r6) << 18) | (@as(u32, g6) << 10) | (@as(u32, b6) << 2);
    }

    /// Continuous 6-bit RGB guide color for FastLED (0xF0 0x5F) Practice Mode:
    /// dim cool blue preview -> quadratic perceptual ease-in -> breathing pure white at beat.
    pub fn guidePadFastLedArgb(p: *const Player, row: u8, col: u8) u32 {
        const lvl = p.guidePadLevel(row, col);
        if (lvl <= 0.0) return 0;
        if (lvl <= 0.15) return packRgb6(0, 3, 12);
        if (lvl < 0.25) return packRgb6(1, 5, 16);
        if (lvl < 1.0) {
            const t: f64 = std.math.clamp((@as(f64, lvl) - 0.25) / 0.75, 0.0, 1.0);
            const e = t * t; // Linear PWM quadratic curve matches perceptual brightness ramp
            const r6: u8 = @intFromFloat(@round(1.0 + 62.0 * e));
            const g6: u8 = @intFromFloat(@round(5.0 + 58.0 * e));
            const b6: u8 = @intFromFloat(@round(16.0 + 47.0 * t));
            return packRgb6(r6, g6, b6);
        }
        if (p.practice_playing) {
            const k = 0.5 + 0.5 * @cos(p.practice_last_ms * 0.0088);
            const w: u8 = @intFromFloat(@round(50.0 + 13.0 * k));
            return packRgb6(w, w, w);
        }
        return packRgb6(63, 63, 63);
    }

    pub fn guidePadVelocity(p: *const Player, row: u8, col: u8) u8 {
        const lvl = p.guidePadLevel(row, col);
        if (lvl <= 0.0) return 0;
        if (lvl < 0.30) return 47; // dim dark blue (next preview — clearly distinct from bright white)
        if (lvl < 0.60) return 1; // dim white (ramping up)
        if (lvl < 0.85) return 2; // medium white
        return 3; // full bright white (press NOW)
    }

    pub fn isGuideChain(p: *const Player, chain: u8) bool {
        if (p.practice_playing) return p.practice_paused_chain != null and p.practice_paused_chain.? == chain;
        if (!p.guide_mode) return false;
        return p.guide_chain != null and p.guide_chain.? == chain;
    }

    fn clearGuideTargets(p: *Player) void {
        @memset(&p.guide_pads, false);
        p.guide_pending = 0;
        p.guide_chain = null;
    }

    fn resetGuide(p: *Player, start_idx: usize) void {
        p.guide_idx = start_idx;
        p.guide_expected_chain = p.current_chain;
        p.clearGuideTargets();
        if (p.guide_mode) {
            if (p.auto_playing) p.previewAutoGuideChord() else p.scanNextGuideChord();
        }
        p.syncGuideLeds();
    }

    /// Scans the next simultaneous chord (notes within 50ms of each other, matching official AutoPlayRunner).
    fn scanNextGuideChord(p: *Player) void {
        const pk = p.pack orelse return;
        p.clearGuideTargets();
        var total_delay: u32 = 0;

        while (p.guide_idx < pk.auto_play.len) {
            const ev = pk.auto_play[p.guide_idx];
            switch (ev) {
                .on => |o| {
                    if (p.guide_expected_chain != p.current_chain) {
                        if (p.guide_pending == 0) p.guide_chain = p.guide_expected_chain;
                        break;
                    }
                    const pidx = @as(usize, o.row) * pack_mod.max_grid + o.col;
                    // Same pad hit again within the threshold starts the next step so both hits are guided.
                    if (p.guide_pads[pidx]) break;
                    p.guide_pads[pidx] = true;
                    p.guide_pending += 1;
                    p.guide_idx += 1;
                },
                .off => {
                    p.guide_idx += 1;
                },
                .chain => |ch| {
                    if (p.guide_pending > 0) {
                        if (ch != p.current_chain) break;
                        p.guide_expected_chain = ch;
                        p.guide_idx += 1;
                    } else {
                        p.guide_expected_chain = ch;
                        p.guide_idx += 1;
                        if (ch != p.current_chain) {
                            p.guide_chain = ch;
                            break;
                        }
                    }
                },
                .delay => |ms| {
                    if (p.guide_pending > 0) {
                        total_delay +|= ms;
                        if (total_delay >= step_group_threshold_ms) break;
                    }
                    p.guide_idx += 1;
                },
            }
        }
    }

    /// Non-mutating lookahead of the next chord while AutoPlay is running.
    fn previewAutoGuideChord(p: *Player) void {
        const pk = p.pack orelse return;
        p.clearGuideTargets();
        var idx = p.auto_idx;
        var exp_chain = p.current_chain;
        var total_delay: u32 = 0;

        while (idx < pk.auto_play.len) : (idx += 1) {
            switch (pk.auto_play[idx]) {
                .on => |o| {
                    if (exp_chain != p.current_chain) {
                        if (p.guide_pending == 0) p.guide_chain = exp_chain;
                        break;
                    }
                    const pidx = @as(usize, o.row) * pack_mod.max_grid + o.col;
                    if (p.guide_pads[pidx]) break;
                    p.guide_pads[pidx] = true;
                    p.guide_pending += 1;
                },
                .off => {},
                .chain => |ch| {
                    if (p.guide_pending > 0) {
                        if (ch != p.current_chain) break;
                    } else {
                        exp_chain = ch;
                        if (ch != p.current_chain) {
                            p.guide_chain = ch;
                            break;
                        }
                    }
                },
                .delay => |ms| {
                    if (p.guide_pending > 0) {
                        total_delay +|= ms;
                        if (total_delay >= step_group_threshold_ms) break;
                    }
                },
            }
        }
    }

    /// Diffs current vs previous guide targets and emits hardware MIDI guide LEDs.
    /// Uses continuous 6-bit RGB ramps/breathing when FastLED (`smooth_guide_rgb`) is active, else 4-step palette velocities.
    pub fn syncGuideLeds(p: *Player) void {
        const pk = p.pack orelse return;
        const want_chain: ?u8 = if (p.practice_playing)
            p.practice_paused_chain
        else if (p.guide_mode)
            p.guide_chain
        else
            null;

        if (p.smooth_guide_rgb) {
            for (0..pk.button_x) |r| {
                for (0..pk.button_y) |col_i| {
                    const idx = r * pack_mod.max_grid + col_i;
                    const want_argb = p.guidePadFastLedArgb(@intCast(r), @intCast(col_i));
                    if (want_argb == p.prev_guide_rgb[idx]) continue;
                    p.prev_guide_rgb[idx] = want_argb;
                    p.prev_guide_pads[idx] = p.guidePadVelocity(@intCast(r), @intCast(col_i));
                    if (want_argb != 0) {
                        p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(col_i), .velocity = 0, .color = want_argb } }) catch {};
                    } else {
                        p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(col_i), .velocity = p.pad_leds[idx].velocity, .color = p.pad_leds[idx].color } }) catch {};
                    }
                }
            }

            if (want_chain != p.prev_guide_chain) {
                if (p.prev_guide_chain) |old_ch| {
                    const ridx = old_ch + 8;
                    if (ridx < pack_mod.round_led_count) {
                        p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = p.ring_leds[ridx].velocity, .color = p.ring_leds[ridx].color } }) catch {};
                    }
                }
                p.prev_guide_chain = want_chain;
                p.prev_guide_chain_rgb = 0;
            }
            if (want_chain) |new_ch| {
                const ridx = new_ch + 8;
                if (ridx < pack_mod.round_led_count) {
                    const chain_argb = if (p.practice_playing) blk: {
                        const k = 0.5 + 0.5 * @cos(p.practice_last_ms * 0.010);
                        const w: u8 = @intFromFloat(@round(24.0 + 39.0 * k));
                        break :blk packRgb6(w, w, w);
                    } else packRgb6(63, 63, 63);
                    if (chain_argb != p.prev_guide_chain_rgb) {
                        p.prev_guide_chain_rgb = chain_argb;
                        p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = 0, .color = chain_argb } }) catch {};
                    }
                }
            }
            return;
        }

        for (0..pk.button_x) |r| {
            for (0..pk.button_y) |col_i| {
                const idx = r * pack_mod.max_grid + col_i;
                const want_vel = p.guidePadVelocity(@intCast(r), @intCast(col_i));
                if (want_vel == p.prev_guide_pads[idx]) continue;
                p.prev_guide_pads[idx] = want_vel;
                const vel: u8 = if (want_vel != 0) want_vel else p.pad_leds[idx].velocity;
                const col_argb: u32 = if (want_vel != 0) palette.argbOf(want_vel) else p.pad_leds[idx].color;
                p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(col_i), .velocity = vel, .color = col_argb } }) catch {};
            }
        }

        if (want_chain != p.prev_guide_chain) {
            if (p.prev_guide_chain) |old_ch| {
                const ridx = old_ch + 8;
                if (ridx < pack_mod.round_led_count) {
                    p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = p.ring_leds[ridx].velocity, .color = p.ring_leds[ridx].color } }) catch {};
                }
            }
            if (want_chain) |new_ch| {
                const ridx = new_ch + 8;
                if (ridx < pack_mod.round_led_count) {
                    p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = 3, .color = palette.argbOf(3) } }) catch {};
                }
            }
            p.prev_guide_chain = want_chain;
        }
    }
};

test "player runs LED animations, ownership off, held loops, and autoplay" {
    const gpa = std.testing.allocator;
    var eng: engine_mod.Engine = .{ .gpa = gpa };
    var player = Player.init(gpa, &eng);
    defer player.deinit();

    const pk = try gpa.create(UniPack);
    pk.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .button_x = 8,
        .button_y = 8,
        .chain_count = 2,
    };
    const pa = pk.arena.allocator();
    const cells = 2 * 8 * 8;
    pk.sound_table = try pa.alloc([]const pack_mod.SoundEntry, cells);
    @memset(pk.sound_table, &.{});
    pk.led_table = try pa.alloc([]const LedAnimation, cells);
    @memset(pk.led_table, &.{});

    const evs = try pa.dupe(pack_mod.LedEvent, &.{
        .{ .pad_on = .{ .row = 0, .col = 0, .color = 0xFFFF0000, .velocity = 5 } },
        .{ .delay = 50 },
        .{ .pad_off = .{ .row = 0, .col = 0 } },
    });
    pk.led_table[0] = try pa.dupe(LedAnimation, &.{.{ .events = evs, .loop = 0 }});

    player.loadPack(pk);
    player.pressPad(0, 0, 100.0, true);
    try std.testing.expectEqual(@as(u8, 5), player.pad_leds[0].velocity);

    // Releasing held loop shuts it down and turns off its owned LED
    player.releasePad(0, 0);
    try std.testing.expectEqual(@as(u8, 0), player.pad_leds[0].velocity);

    // Guide mode groups simultaneous chords (<50ms), emits white (velocity 3) for all pads in the chord,
    // accepts presses in any order, and advances only after the full chord is played.
    pk.auto_play = try pa.dupe(pack_mod.AutoPlayEvent, &.{
        .{ .on = .{ .row = 1, .col = 2 } },
        .{ .delay = 15 }, // < 50ms -> part of same chord
        .{ .on = .{ .row = 3, .col = 4 } },
        .{ .delay = 200 }, // >= 50ms -> next step
        .{ .chain = 1 },
        .{ .on = .{ .row = 5, .col = 6 } },
    });
    player.clearOutEvents();
    player.setGuideMode(true);
    try std.testing.expect(player.isGuidePad(1, 2));
    try std.testing.expect(player.isGuidePad(3, 4));
    try std.testing.expect(!player.isGuidePad(5, 6));
    const evs1 = player.drainOutEvents();
    try std.testing.expectEqual(@as(usize, 2), evs1.len);
    try std.testing.expectEqual(@as(u8, 3), evs1[0].pad.velocity);
    try std.testing.expectEqual(@as(u8, 3), evs1[1].pad.velocity);

    // Press second pad first -> first pad stays guided in white
    player.clearOutEvents();
    player.pressPad(3, 4, 200.0, true);
    try std.testing.expect(player.isGuidePad(1, 2));
    try std.testing.expect(!player.isGuidePad(3, 4));
    try std.testing.expect(!player.isGuideChain(1));

    // Press remaining pad -> chord completes, now guides chain 1
    player.clearOutEvents();
    player.pressPad(1, 2, 220.0, true);
    try std.testing.expect(!player.isGuidePad(1, 2));
    try std.testing.expect(player.isGuideChain(1));

    // Switch to chain 1 -> now guides (5, 6)
    player.setChain(1);
    try std.testing.expect(!player.isGuideChain(1));
    try std.testing.expect(player.isGuidePad(5, 6));

    // Practice Mode: behaves like Guide Mode (waits for user, never skips), previews upcoming pads with gradual brightening,
    // pauses at chain switch, and syncs gradual white brightness (117->1->2->3) to Launchpad.
    pk.auto_play = try pa.dupe(pack_mod.AutoPlayEvent, &.{
        .{ .on = .{ .row = 1, .col = 2 } },
        .{ .delay = 800 },
        .{ .on = .{ .row = 3, .col = 4 } },
        .{ .delay = 200 },
        .{ .chain = 1 },
        .{ .on = .{ .row = 5, .col = 6 } },
    });
    player.setGuideMode(false);
    player.clearOutEvents();
    player.startPractice(1000.0);
    try std.testing.expect(player.practice_playing);
    // First pad waits at full brightness (vel 3); next 1 chord (3,4) previews in dim blue (vel 47)
    try std.testing.expectEqual(@as(u8, 3), player.guidePadVelocity(1, 2));
    try std.testing.expectEqual(@as(u8, 47), player.guidePadVelocity(3, 4));
    // Even after waiting 5 seconds without pressing, Practice Mode still waits on (1,2)
    player.tick(6000.0);
    try std.testing.expectEqual(@as(u8, 3), player.guidePadVelocity(1, 2));
    // Press (1,2) -> advances to (3,4) 800ms away: stays dim blue preview (vel 47) until final 180ms ramp, then full white (vel 3)
    player.pressPad(1, 2, 6000.0, false);
    try std.testing.expectEqual(@as(u8, 0), player.guidePadVelocity(1, 2));
    try std.testing.expectEqual(@as(u8, 47), player.guidePadVelocity(3, 4));
    player.tick(6500.0); // 300ms remaining -> still dim preview
    try std.testing.expectEqual(@as(u8, 47), player.guidePadVelocity(3, 4));
    player.tick(6740.0); // 60ms remaining -> brightening (vel 2)
    try std.testing.expectEqual(@as(u8, 2), player.guidePadVelocity(3, 4));
    player.tick(6800.0); // due now -> full brightness (vel 3)
    try std.testing.expectEqual(@as(u8, 3), player.guidePadVelocity(3, 4));
    // Press (3,4) -> pauses automatically at chain 1 transition
    player.pressPad(3, 4, 6800.0, false);
    try std.testing.expectEqual(@as(?u8, 1), player.practice_paused_chain);
    try std.testing.expect(player.isGuideChain(1));
    // Switch to chain 1 -> resumes and waits at full brightness on (5,6)
    player.setChain(1);
    try std.testing.expectEqual(@as(?u8, null), player.practice_paused_chain);
    try std.testing.expectEqual(@as(u8, 3), player.guidePadVelocity(5, 6));

    // FastLED-only smooth RGB Practice Mode: continuous 6-bit RGB ramp & breathing white pulse
    player.stopPractice();
    player.setChain(0);
    player.smooth_guide_rgb = true;
    player.clearOutEvents();
    player.startPractice(1000.0);
    // Next chord (3,4) previews in subtle dim cool blue (0,3,12)
    try std.testing.expectEqual(Player.packRgb6(0, 3, 12), player.guidePadFastLedArgb(3, 4));
    // Press (1,2) -> (3,4) is 800ms away, enters smooth 320ms RGB ease-in ramp at 480ms
    player.pressPad(1, 2, 1000.0, false);
    player.tick(1560.0); // 240ms remaining (t=0.25)
    const c_early = player.guidePadFastLedArgb(3, 4);
    player.tick(1640.0); // 160ms remaining (t=0.50)
    const c_mid = player.guidePadFastLedArgb(3, 4);
    player.tick(1720.0); // 80ms remaining (t=0.75)
    const c_late = player.guidePadFastLedArgb(3, 4);
    try std.testing.expect(((c_early >> 18) & 0x3F) < ((c_mid >> 18) & 0x3F));
    try std.testing.expect(((c_mid >> 18) & 0x3F) < ((c_late >> 18) & 0x3F));
    // Due now -> bright breathing white within [50..63]
    player.tick(1800.0);
    const c_now = player.guidePadFastLedArgb(3, 4);
    const w_now = (c_now >> 18) & 0x3F;
    try std.testing.expect(w_now >= 50 and w_now <= 63);
    try std.testing.expectEqual(w_now, (c_now >> 10) & 0x3F);
    try std.testing.expectEqual(w_now, (c_now >> 2) & 0x3F);
}
