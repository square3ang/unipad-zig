//! Reusable floating dropdown menu widget adapted from Actuon's dropdown pattern.
const std = @import("std");
const c = @import("c");
const gfx = @import("../render/gfx.zig");

pub const Target = enum {
    none,
    midi_model,
    midi_port,
    audio_device,
};

pub const Dropdown = struct {
    target: Target = .none,
    labels: []const []const u8 = &.{},
    selected: usize = 0,
    scroll: i32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn isOpen(d: *const Dropdown) bool {
        return d.target != .none;
    }

    pub fn close(d: *Dropdown) void {
        d.target = .none;
    }

    /// Draws the trigger field; returns true if clicked (caller opens/toggles the dropdown).
    pub fn trigger(d: *Dropdown, g: *gfx.Gfx, target: Target, x: f32, y: f32, w: f32, h: f32, current: []const u8, allow_click: bool) bool {
        const open_this = d.target == target;
        if (open_this) {
            d.x = x;
            d.y = y;
            d.w = w;
            d.h = h;
        }
        const hovered = allow_click and g.hit(x, y, w, h);
        const stroke = if (open_this) gfx.accent else if (hovered) gfx.dim else gfx.border_col;
        const fill = if (hovered or open_this) gfx.panel_col else gfx.card;
        g.roundBox(x, y, w, h, 7, fill, stroke);
        g.textClip(current, x + 12, y + (h - 16) / 2, @max(w - 36, 10), 14, gfx.white);
        g.triDown(x + w - 15, y + h / 2, 9, open_this, if (open_this) gfx.accent else gfx.dim);

        if (allow_click and g.clickIn(x, y, w, h)) {
            if (open_this) {
                d.close();
                return false;
            }
            d.x = x;
            d.y = y;
            d.w = w;
            d.h = h;
            return true;
        }
        return false;
    }

    pub fn show(d: *Dropdown, target: Target, labels: []const []const u8, selected: usize) void {
        d.target = target;
        d.labels = labels;
        d.selected = @min(selected, labels.len -| 1);
        d.scroll = @intCast(d.selected -| 3);
    }

    pub fn handleKey(d: *Dropdown, sc: c.SDL_Scancode) ?usize {
        if (!d.isOpen() or d.labels.len == 0) return null;
        switch (sc) {
            c.SDL_SCANCODE_ESCAPE => {
                d.close();
                return null;
            },
            c.SDL_SCANCODE_UP => {
                if (d.selected > 0) d.selected -= 1;
                return null;
            },
            c.SDL_SCANCODE_DOWN => {
                if (d.selected + 1 < d.labels.len) d.selected += 1;
                return null;
            },
            c.SDL_SCANCODE_RETURN, c.SDL_SCANCODE_KP_ENTER => {
                const picked = d.selected;
                d.close();
                return picked;
            },
            else => return null,
        }
    }

    /// Draw last over all other UI. Consumes `click` when open; returns selected index on pick.
    pub fn drawPopup(d: *Dropdown, g: *gfx.Gfx, click: bool) ?usize {
        if (!d.isOpen() or d.labels.len == 0) return null;

        const row_h: f32 = 30;
        const max_shown: usize = 8;
        const shown = @min(d.labels.len, max_shown);
        const max_scroll: i32 = @intCast(d.labels.len -| shown);

        const pop_w = d.w;
        const pop_h = row_h * @as(f32, @floatFromInt(shown)) + 10;
        const below = d.y + d.h + 4;
        const pop_y = if (below + pop_h <= g.h - 12) below else @max(12.0, d.y - pop_h - 4);
        const pop_x = d.x;

        if (g.wheel != 0 and g.hit(pop_x, pop_y, pop_w, pop_h)) {
            d.scroll -= @intFromFloat(@round(g.wheel * 2.0));
        }
        d.scroll = std.math.clamp(d.scroll, 0, max_scroll);
        const first: usize = @intCast(d.scroll);

        // Soft drop shadow
        g.round(pop_x - 3, pop_y + 4, pop_w + 6, pop_h + 4, 10, .{ .r = 0, .g = 0, .b = 0, .a = 120 });
        g.roundBox(pop_x, pop_y, pop_w, pop_h, 8, .{ .r = 16, .g = 19, .b = 28 }, gfx.accent.alpha(180));

        const has_bar = d.labels.len > shown;
        const item_w = if (has_bar) pop_w - 16 else pop_w - 10;
        var chosen: ?usize = null;

        for (0..shown) |vi| {
            const idx = first + vi;
            const ry = pop_y + 5 + row_h * @as(f32, @floatFromInt(vi));
            const hovered = g.hit(pop_x + 5, ry, item_w, row_h);
            const active = idx == d.selected;

            if (active) {
                g.round(pop_x + 5, ry + 1, item_w, row_h - 2, 6, gfx.accent.alpha(42));
                g.round(pop_x + 7, ry + 6, 3, row_h - 12, 1.5, gfx.accent);
            } else if (hovered) {
                g.round(pop_x + 5, ry + 1, item_w, row_h - 2, 6, gfx.panel_col);
            }

            g.textClip(
                d.labels[idx],
                pop_x + 16,
                ry + (row_h - 16) / 2,
                @max(item_w - 22, 10),
                14,
                if (active) gfx.white else if (hovered) gfx.white else gfx.dim,
            );
            if (click and hovered) chosen = idx;
        }

        if (has_bar) {
            const track_x = pop_x + pop_w - 8;
            const track_y = pop_y + 7;
            const track_h = pop_h - 14;
            const thumb_h = @max(track_h * @as(f32, @floatFromInt(shown)) / @as(f32, @floatFromInt(d.labels.len)), 20.0);
            const t = if (max_scroll > 0) @as(f32, @floatFromInt(d.scroll)) / @as(f32, @floatFromInt(max_scroll)) else 0;
            g.round(track_x, track_y + (track_h - thumb_h) * t, 4, thumb_h, 2, gfx.border_col);
        }

        if (click) d.close();
        return chosen;
    }
};

test "dropdown keyboard navigation selects and closes" {
    var d: Dropdown = .{};
    const items = [_][]const u8{ "A", "B", "C" };
    d.show(.midi_model, &items, 0);
    try std.testing.expect(d.isOpen());
    try std.testing.expectEqual(@as(?usize, null), d.handleKey(c.SDL_SCANCODE_DOWN));
    try std.testing.expectEqual(@as(usize, 1), d.selected);
    try std.testing.expectEqual(@as(?usize, 1), d.handleKey(c.SDL_SCANCODE_RETURN));
    try std.testing.expect(!d.isOpen());
}
