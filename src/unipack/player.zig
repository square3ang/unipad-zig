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
    pad: struct { row: u8, col: u8, velocity: u8 },
    ring: struct { idx: u8, velocity: u8 }, // 0..31 round, 32 logo
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

const step_group_threshold_ms: u32 = 50;

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

    // AutoPlay & simultaneous-chord Guide state
    auto_playing: bool = false,
    auto_idx: usize = 0,
    auto_next_ms: f64 = 0,
    guide_idx: usize = 0,
    guide_expected_chain: u8 = 0,
    guide_pads: [pack_mod.max_grid * pack_mod.max_grid]bool = @splat(false),
    guide_pending: usize = 0,
    guide_chain: ?u8 = null,
    prev_guide_pads: [pack_mod.max_grid * pack_mod.max_grid]bool = @splat(false),
    prev_guide_chain: ?u8 = null,

    pub fn init(gpa: std.mem.Allocator, engine: *engine_mod.Engine) Player {
        return .{ .gpa = gpa, .engine = engine };
    }

    pub fn deinit(p: *Player) void {
        p.unload();
        p.anims.deinit(p.gpa);
        p.wormholes.deinit(p.gpa);
        p.out_events.deinit(p.gpa);
    }

    pub fn unload(p: *Player) void {
        p.stopAutoPlay();
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
        if (p.guide_mode and !p.auto_playing) {
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
        @memset(&p.prev_guide_pads, false);
        p.prev_guide_chain = null;
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

        // 2. Advance simultaneous-chord Guide Mode when user plays any pending pad in the chord
        if (p.guide_mode and !p.auto_playing) {
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
        if (p.guide_mode) p.syncGuideLeds();
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

        // 2. Step AutoPlay
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
        }

        // 3. Advance LED animations
        p.tickAnims(now_ms);
        if (p.guide_mode) {
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
        p.out_events.append(p.gpa, .{ .pad = .{ .row = row, .col = col, .velocity = velocity } }) catch {};
    }

    fn clearPadLedIfOwned(p: *Player, row: u8, col: u8, orow: u8, ocol: u8, ochain: u8) void {
        const idx = @as(usize, row) * pack_mod.max_grid + col;
        const cell = &p.pad_leds[idx];
        if (!cell.owned) return;
        if (cell.owner_pad_row == orow and cell.owner_pad_col == ocol and cell.owner_chain == ochain) {
            cell.* = .{};
            const keep_white = p.isGuidePad(row, col);
            p.out_events.append(p.gpa, .{ .pad = .{ .row = row, .col = col, .velocity = if (keep_white) 3 else 0 } }) catch {};
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
        p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = velocity } }) catch {};
    }

    fn clearRingLedIfOwned(p: *Player, idx: u8, orow: u8, ocol: u8, ochain: u8) void {
        if (idx > pack_mod.logo_led_index) return;
        const cell = &p.ring_leds[idx];
        if (!cell.owned) return;
        if (cell.owner_pad_row == orow and cell.owner_pad_col == ocol and cell.owner_chain == ochain) {
            cell.* = .{};
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 0 } }) catch {};
            if (p.show_chain and idx == p.current_chain + 8) p.refreshChainLed();
        }
    }

    fn clearChainIndicator(p: *Player, ch: u8) void {
        const idx = ch + 8;
        if (idx >= pack_mod.round_led_count) return;
        if (!p.ring_leds[idx].owned) {
            p.ring_leds[idx] = .{};
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 0 } }) catch {};
        }
    }

    pub fn refreshChainLed(p: *Player) void {
        if (!p.show_chain) return;
        const idx = p.current_chain + 8;
        if (idx >= pack_mod.round_led_count) return;
        if (!p.ring_leds[idx].owned) {
            p.ring_leds[idx] = .{ .color = palette.argbOf(3), .velocity = 3, .owned = false };
            p.out_events.append(p.gpa, .{ .ring = .{ .idx = idx, .velocity = 3 } }) catch {};
        }
    }

    /// Re-emits current LED state (used when a hardware Launchpad newly connects).
    pub fn pushFullLedSync(p: *Player) void {
        p.out_events.append(p.gpa, .clear) catch {};
        const pk = p.pack orelse return;
        for (0..pk.button_x) |r| {
            for (0..pk.button_y) |c_idx| {
                const cell = p.pad_leds[r * pack_mod.max_grid + c_idx];
                if (cell.velocity != 0) {
                    p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(c_idx), .velocity = cell.velocity } }) catch {};
                }
            }
        }
        for (0..pack_mod.logo_led_index + 1) |i| {
            const cell = p.ring_leds[i];
            if (cell.velocity != 0) {
                p.out_events.append(p.gpa, .{ .ring = .{ .idx = @intCast(i), .velocity = cell.velocity } }) catch {};
            }
        }
        @memset(&p.prev_guide_pads, false);
        p.prev_guide_chain = null;
        p.syncGuideLeds();
    }

    pub fn drainOutEvents(p: *Player) []const LedOutEvent {
        return p.out_events.items;
    }

    pub fn clearOutEvents(p: *Player) void {
        p.out_events.clearRetainingCapacity();
    }

    pub fn isGuidePad(p: *const Player, row: u8, col: u8) bool {
        if (!p.guide_mode) return false;
        return p.guide_pads[@as(usize, row) * pack_mod.max_grid + col];
    }

    pub fn isGuideChain(p: *const Player, chain: u8) bool {
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

    /// Diffs current vs previous guide targets and emits hardware MIDI white LEDs (velocity 3).
    pub fn syncGuideLeds(p: *Player) void {
        const pk = p.pack orelse return;
        for (0..pk.button_x) |r| {
            for (0..pk.button_y) |col_i| {
                const idx = r * pack_mod.max_grid + col_i;
                const want = p.guide_mode and p.guide_pads[idx];
                if (want == p.prev_guide_pads[idx]) continue;
                p.prev_guide_pads[idx] = want;
                const vel: u8 = if (want) 3 else p.pad_leds[idx].velocity;
                p.out_events.append(p.gpa, .{ .pad = .{ .row = @intCast(r), .col = @intCast(col_i), .velocity = vel } }) catch {};
            }
        }

        const want_chain: ?u8 = if (p.guide_mode) p.guide_chain else null;
        if (want_chain != p.prev_guide_chain) {
            if (p.prev_guide_chain) |old_ch| {
                const ridx = old_ch + 8;
                if (ridx < pack_mod.round_led_count) {
                    p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = p.ring_leds[ridx].velocity } }) catch {};
                }
            }
            if (want_chain) |new_ch| {
                const ridx = new_ch + 8;
                if (ridx < pack_mod.round_led_count) {
                    p.out_events.append(p.gpa, .{ .ring = .{ .idx = ridx, .velocity = 3 } }) catch {};
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
}
