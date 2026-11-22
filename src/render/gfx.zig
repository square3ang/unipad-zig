//! Sokol-gfx + SDL3_ttf 2D batched renderer adapted from Actuon.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

const os = builtin.os.tag;
const vert_spv = if (os == .linux) @embedFile("sprite.vert") else "";
const frag_spv = if (os == .linux) @embedFile("sprite.frag") else "";
const vert_src: [:0]const u8 = if (os != .linux) @embedFile("sprite.vert") else "";
const frag_src: [:0]const u8 = if (os != .linux) @embedFile("sprite.frag") else "";
const shader_entry: [:0]const u8 = if (os == .macos) "main0" else "main";

const font_medium = @embedFile("font_medium");
const font_heavy = @embedFile("font_heavy");
const heavy_from_size = 24;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn alpha(col: Color, a: u8) Color {
        return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
    }

    pub fn fromArgb(argb: u32) Color {
        return .{
            .a = @intCast((argb >> 24) & 0xFF),
            .r = @intCast((argb >> 16) & 0xFF),
            .g = @intCast((argb >> 8) & 0xFF),
            .b = @intCast(argb & 0xFF),
        };
    }
};

pub const bg: Color = .{ .r = 10, .g = 12, .b = 18 };
pub const bg_bottom: Color = .{ .r = 16, .g = 20, .b = 30 };
pub const surface: Color = .{ .r = 18, .g = 21, .b = 30 };
pub const card: Color = .{ .r = 23, .g = 27, .b = 38 };
pub const panel_col: Color = .{ .r = 30, .g = 35, .b = 49 };
pub const border_col: Color = .{ .r = 52, .g = 60, .b = 82 };
pub const white: Color = .{ .r = 240, .g = 244, .b = 252 };
pub const dim: Color = .{ .r = 148, .g = 158, .b = 182 };
pub const accent: Color = .{ .r = 64, .g = 140, .b = 255 };
pub const good: Color = .{ .r = 48, .g = 212, .b = 124 };
pub const warn: Color = .{ .r = 245, .g = 176, .b = 65 };
pub const danger: Color = .{ .r = 232, .g = 76, .b = 76 };

pub fn mix(a: Color, b: Color, t: f32) Color {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * k),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * k),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * k),
        .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * k),
    };
}

pub const Texture = struct {
    image: c.sg_image = .{ .id = 0 },
    view: c.sg_view = .{ .id = 0 },
    w: f32,
    h: f32,
};

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    col: [4]u8,
};

fn vert(x: f32, y: f32, col: Color) Vertex {
    return .{ .x = x, .y = y, .u = -1, .v = -1, .col = .{ col.r, col.g, col.b, col.a } };
}

const State = struct {
    add: bool = false,
    clip: ?c.SDL_Rect = null,

    fn same(a: State, b: State) bool {
        if (a.add != b.add) return false;
        const ac = a.clip orelse return b.clip == null;
        const bc = b.clip orelse return false;
        return ac.x == bc.x and ac.y == bc.y and ac.w == bc.w and ac.h == bc.h;
    }
};

const Cmd = struct {
    tex: ?*Texture,
    state: State,
    first: u32,
    count: u32,
};

const Batch = struct {
    verts: std.ArrayList(Vertex) = .empty,
    idx: std.ArrayList(u32) = .empty,
    cmds: std.ArrayList(Cmd) = .empty,

    fn reset(b: *Batch) void {
        b.verts.clearRetainingCapacity();
        b.idx.clearRetainingCapacity();
        b.cmds.clearRetainingCapacity();
    }

    fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        b.verts.deinit(gpa);
        b.idx.deinit(gpa);
        b.cmds.deinit(gpa);
    }

    fn push(b: *Batch, gpa: std.mem.Allocator, tex: ?*Texture, state: State, v: []const Vertex, idx: []const u32) void {
        b.verts.ensureUnusedCapacity(gpa, v.len) catch return;
        b.idx.ensureUnusedCapacity(gpa, idx.len) catch return;
        b.cmds.ensureUnusedCapacity(gpa, 1) catch return;
        const base: u32 = @intCast(b.verts.items.len);
        const first: u32 = @intCast(b.idx.items.len);
        b.verts.appendSliceAssumeCapacity(v);
        for (idx) |i| b.idx.appendAssumeCapacity(base + i);
        if (b.cmds.items.len > 0) {
            const last = &b.cmds.items[b.cmds.items.len - 1];
            const fits_tex = tex == null or last.tex == null or last.tex == tex;
            if (fits_tex and last.state.same(state)) {
                if (last.tex == null and tex != null) last.tex = tex;
                last.count += @intCast(idx.len);
                return;
            }
        }
        b.cmds.appendAssumeCapacity(.{ .tex = tex, .state = state, .first = first, .count = @intCast(idx.len) });
    }
};

const TextKey = struct { hash: u64, size: u16 };
const TextEntry = struct { tex: *Texture, w: f32, h: f32, frame: u64 };

pub const Gfx = struct {
    gpa: std.mem.Allocator,
    win: *c.SDL_Window,
    pipelines: [2]c.sg_pipeline = undefined, // blend, add
    sampler: c.sg_sampler = undefined,
    white: *Texture = undefined,
    batch: Batch = .{},
    state: State = .{},
    dead: std.ArrayList(*Texture) = .empty,
    live_textures: usize = 0,
    vbuf: c.sg_buffer = .{ .id = 0 },
    ibuf: c.sg_buffer = .{ .id = 0 },
    vbuf_size: usize = 0,
    ibuf_size: usize = 0,
    fonts: [font_sizes.len]?*c.TTF_Font = @splat(null),
    text_cache: std.AutoHashMapUnmanaged(TextKey, TextEntry) = .empty,
    frame: u64 = 0,
    w: f32 = 1280,
    h: f32 = 800,

    mx: f32 = -1,
    my: f32 = -1,
    down: bool = false,
    clicked: bool = false,
    wheel: f32 = 0,

    const font_sizes = [_]u16{ 12, 14, 16, 18, 20, 24, 32, 42 };

    pub fn init(gpa: std.mem.Allocator, win: *c.SDL_Window) !Gfx {
        if (!c.TTF_Init()) return error.Ttf;
        if (!c.rb_setup(win)) {
            std.log.err("no graphics device: {s}", .{c.SDL_GetError()});
            return error.GpuDevice;
        }
        var g: Gfx = .{ .gpa = gpa, .win = win };
        const sh = c.sg_make_shader(&shaderDesc());
        g.pipelines = .{ makePipeline(sh, false), makePipeline(sh, true) };
        var sd = std.mem.zeroes(c.sg_sampler_desc);
        sd.min_filter = c.SG_FILTER_LINEAR;
        sd.mag_filter = c.SG_FILTER_LINEAR;
        sd.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
        sd.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
        g.sampler = c.sg_make_sampler(&sd);

        const pixel = [4]u8{ 255, 255, 255, 255 };
        g.white = g.textureFromPixels(&pixel, 1, 1, 4) orelse return error.GpuTexture;
        for (font_sizes, 0..) |sz, i| {
            const data: []const u8 = if (sz >= heavy_from_size) font_heavy else font_medium;
            const io = c.SDL_IOFromConstMem(data.ptr, data.len);
            g.fonts[i] = c.TTF_OpenFontIO(io, true, @floatFromInt(sz));
            if (g.fonts[i] != null) c.TTF_SetFontHinting(g.fonts[i], c.TTF_HINTING_NONE);
        }
        return g;
    }

    pub fn deinit(g: *Gfx) void {
        var it = g.text_cache.valueIterator();
        while (it.next()) |e| g.destroyTexture(e.tex);
        g.text_cache.deinit(g.gpa);
        for (g.fonts) |f| if (f != null) c.TTF_CloseFont(f);
        c.TTF_Quit();
        g.destroyTexture(g.white);
        g.reapTextures();
        g.dead.deinit(g.gpa);
        g.batch.deinit(g.gpa);
        c.rb_shutdown();
    }

    fn shaderDesc() c.sg_shader_desc {
        var d = std.mem.zeroes(c.sg_shader_desc);
        if (os == .linux) {
            d.vertex_func.bytecode = .{ .ptr = vert_spv.ptr, .size = vert_spv.len };
            d.fragment_func.bytecode = .{ .ptr = frag_spv.ptr, .size = frag_spv.len };
        } else {
            d.vertex_func.source = vert_src.ptr;
            d.fragment_func.source = frag_src.ptr;
        }
        d.vertex_func.entry = shader_entry.ptr;
        d.fragment_func.entry = shader_entry.ptr;
        for (0..3) |i| {
            d.attrs[i].base_type = c.SG_SHADERATTRBASETYPE_FLOAT;
            d.attrs[i].hlsl_sem_name = "TEXCOORD";
            d.attrs[i].hlsl_sem_index = @intCast(i);
        }
        d.uniform_blocks[0].stage = c.SG_SHADERSTAGE_VERTEX;
        d.uniform_blocks[0].size = @sizeOf([4]f32);
        d.views[0].texture.stage = c.SG_SHADERSTAGE_FRAGMENT;
        d.views[0].texture.image_type = c.SG_IMAGETYPE_2D;
        d.views[0].texture.sample_type = c.SG_IMAGESAMPLETYPE_FLOAT;
        d.samplers[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        d.samplers[0].sampler_type = c.SG_SAMPLERTYPE_FILTERING;
        d.texture_sampler_pairs[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        d.samplers[0].spirv_set1_binding_n = 1;
        d.samplers[0].hlsl_register_s_n = 1;
        d.samplers[0].msl_sampler_n = 1;
        return d;
    }

    fn makePipeline(sh: c.sg_shader, add: bool) c.sg_pipeline {
        var d = std.mem.zeroes(c.sg_pipeline_desc);
        d.shader = sh;
        d.layout.buffers[0].stride = @sizeOf(Vertex);
        d.layout.attrs[0].format = c.SG_VERTEXFORMAT_FLOAT2;
        d.layout.attrs[0].offset = @offsetOf(Vertex, "x");
        d.layout.attrs[1].format = c.SG_VERTEXFORMAT_FLOAT2;
        d.layout.attrs[1].offset = @offsetOf(Vertex, "u");
        d.layout.attrs[2].format = c.SG_VERTEXFORMAT_UBYTE4N;
        d.layout.attrs[2].offset = @offsetOf(Vertex, "col");
        d.index_type = c.SG_INDEXTYPE_UINT32;
        d.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = c.SG_BLENDFACTOR_SRC_ALPHA,
            .dst_factor_rgb = if (add) c.SG_BLENDFACTOR_ONE else c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_rgb = c.SG_BLENDOP_ADD,
            .src_factor_alpha = if (add) c.SG_BLENDFACTOR_ZERO else c.SG_BLENDFACTOR_ONE,
            .dst_factor_alpha = if (add) c.SG_BLENDFACTOR_ONE else c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_alpha = c.SG_BLENDOP_ADD,
        };
        return c.sg_make_pipeline(&d);
    }

    pub fn beginFrame(g: *Gfx) void {
        g.frame += 1;
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(g.win, &w, &h);
        g.w = @floatFromInt(@max(w, 1));
        g.h = @floatFromInt(@max(h, 1));
        g.batch.reset();
        g.state = .{};
        if (g.text_cache.count() > 1024) g.evictText();
    }

    fn evictText(g: *Gfx) void {
        var it = g.text_cache.iterator();
        var drop: std.ArrayList(TextKey) = .empty;
        defer drop.deinit(g.gpa);
        while (it.next()) |e| {
            if (e.value_ptr.frame + 120 < g.frame) drop.append(g.gpa, e.key_ptr.*) catch return;
        }
        for (drop.items) |k| {
            g.destroyTexture(g.text_cache.get(k).?.tex);
            _ = g.text_cache.remove(k);
        }
    }

    pub fn present(g: *Gfx) void {
        defer g.reapTextures();
        defer g.batch.reset();
        const ready = g.batch.cmds.items.len > 0;
        if (ready) {
            const verts = std.mem.sliceAsBytes(g.batch.verts.items);
            const idx = std.mem.sliceAsBytes(g.batch.idx.items);
            growBuffer(&g.vbuf, &g.vbuf_size, verts.len, false);
            growBuffer(&g.ibuf, &g.ibuf_size, idx.len, true);
            writeBuffer(g.vbuf, verts);
            writeBuffer(g.ibuf, idx);
        }
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(g.win, &w, &h);
        w = @max(w, 1);
        h = @max(h, 1);
        var pass = std.mem.zeroes(c.sg_pass);
        pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
        pass.action.colors[0].clear_value = .{ .r = @as(f32, bg.r) / 255, .g = @as(f32, bg.g) / 255, .b = @as(f32, bg.b) / 255, .a = 1 };
        pass.swapchain = c.rb_swapchain(w, h);
        c.sg_begin_pass(&pass);
        if (ready) {
            const size = [4]f32{ g.w, g.h, 0, 0 };
            const uniforms: c.sg_range = .{ .ptr = &size, .size = @sizeOf(@TypeOf(size)) };
            var bind = std.mem.zeroes(c.sg_bindings);
            bind.vertex_buffers[0] = g.vbuf;
            bind.index_buffer = g.ibuf;
            bind.samplers[0] = g.sampler;
            const whole: c.SDL_Rect = .{ .x = 0, .y = 0, .w = w, .h = h };
            var add: ?bool = null;
            for (g.batch.cmds.items) |d| {
                if (add != d.state.add) {
                    add = d.state.add;
                    c.sg_apply_pipeline(g.pipelines[@intFromBool(d.state.add)]);
                    c.sg_apply_uniforms(0, &uniforms);
                }
                const tex = d.tex orelse g.white;
                bind.views[0] = if (tex.view.id != 0) tex.view else g.white.view;
                c.sg_apply_bindings(&bind);
                var box = whole;
                if (d.state.clip) |r| _ = c.SDL_GetRectIntersection(&whole, &r, &box);
                c.sg_apply_scissor_rect(box.x, box.y, box.w, box.h, true);
                c.sg_draw(@intCast(d.first), @intCast(d.count), 1);
            }
        }
        c.sg_end_pass();
        c.sg_commit();
        c.rb_present();
    }

    fn growBuffer(buf: *c.sg_buffer, have: *usize, need: usize, index: bool) void {
        if (buf.id != 0 and have.* >= need) return;
        if (buf.id != 0) c.sg_destroy_buffer(buf.*);
        have.* = @max(need * 2, 1 << 16);
        var d = std.mem.zeroes(c.sg_buffer_desc);
        d.size = have.*;
        d.usage.vertex_buffer = !index;
        d.usage.index_buffer = index;
        d.usage.write_transient = true;
        buf.* = c.sg_make_buffer(&d);
    }

    fn writeBuffer(buf: c.sg_buffer, bytes: []const u8) void {
        var d = std.mem.zeroes(c.sg_write_buffer_desc);
        d.src.data = .{ .ptr = bytes.ptr, .size = bytes.len };
        d.dst.buffer = buf;
        d.size = bytes.len;
        c.sg_write_buffer_transient(&d);
    }

    fn textureFromPixels(g: *Gfx, px: [*]const u8, w: c_int, h: c_int, pitch: usize) ?*Texture {
        if (w <= 0 or h <= 0) return null;
        g.dead.ensureTotalCapacity(g.gpa, g.live_textures + 1) catch return null;
        const t = g.gpa.create(Texture) catch return null;
        g.live_textures += 1;
        t.* = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        const tight = uw * 4;
        var packed_px: []u8 = &.{};
        defer if (packed_px.len > 0) g.gpa.free(packed_px);
        if (pitch != tight) {
            packed_px = g.gpa.alloc(u8, tight * uh) catch {
                g.live_textures -= 1;
                g.gpa.destroy(t);
                return null;
            };
            for (0..uh) |row| @memcpy(packed_px[row * tight ..][0..tight], px[row * pitch ..][0..tight]);
        }
        var d = std.mem.zeroes(c.sg_image_desc);
        d.width = w;
        d.height = h;
        d.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        d.data = .{ .ptr = if (pitch != tight) packed_px.ptr else px, .size = tight * uh };
        const image = c.sg_make_image(&d);
        var v = std.mem.zeroes(c.sg_view_desc);
        v.texture.image = image;
        const view = c.sg_make_view(&v);
        if (c.sg_query_view_state(view) != c.SG_RESOURCESTATE_VALID) {
            c.sg_destroy_view(view);
            c.sg_destroy_image(image);
            g.live_textures -= 1;
            g.gpa.destroy(t);
            return null;
        }
        t.image = image;
        t.view = view;
        return t;
    }

    fn destroyTexture(g: *Gfx, t: *Texture) void {
        g.dead.appendAssumeCapacity(t);
    }

    fn reapTextures(g: *Gfx) void {
        g.live_textures -= g.dead.items.len;
        for (g.dead.items) |t| {
            if (t.view.id != 0) c.sg_destroy_view(t.view);
            if (t.image.id != 0) c.sg_destroy_image(t.image);
            g.gpa.destroy(t);
        }
        g.dead.clearRetainingCapacity();
    }

    pub fn additive(g: *Gfx, on: bool) void {
        g.state.add = on;
    }

    pub fn clip(g: *Gfx, x: f32, y: f32, w: f32, h: f32) void {
        g.state.clip = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(w), .h = @intFromFloat(h) };
    }

    pub fn unclip(g: *Gfx) void {
        g.state.clip = null;
    }

    pub fn hit(g: *const Gfx, x: f32, y: f32, w: f32, h: f32) bool {
        return g.mx >= x and g.mx < x + w and g.my >= y and g.my < y + h;
    }

    pub fn clickIn(g: *Gfx, x: f32, y: f32, w: f32, h: f32) bool {
        if (!g.clicked or !g.hit(x, y, w, h)) return false;
        g.clicked = false;
        return true;
    }

    pub fn rect(g: *Gfx, x: f32, y: f32, w: f32, h: f32, col: Color) void {
        const v = [4]Vertex{ vert(x, y, col), vert(x + w, y, col), vert(x + w, y + h, col), vert(x, y + h, col) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    pub fn vgrad(g: *Gfx, x: f32, y: f32, w: f32, h: f32, top: Color, bottom: Color) void {
        const v = [4]Vertex{ vert(x, y, top), vert(x + w, y, top), vert(x + w, y + h, bottom), vert(x, y + h, bottom) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    pub fn roundBox(g: *Gfx, x: f32, y: f32, w: f32, h: f32, radius: f32, fill: Color, stroke: Color) void {
        g.roundBoxThick(x, y, w, h, radius, 1, fill, stroke);
    }

    pub fn roundBoxThick(g: *Gfx, x: f32, y: f32, w: f32, h: f32, radius: f32, thick: f32, fill: Color, stroke: Color) void {
        g.round(x, y, w, h, radius, stroke);
        if (w > thick * 2 and h > thick * 2) {
            g.round(x + thick, y + thick, w - thick * 2, h - thick * 2, @max(radius - thick, 0), fill);
        }
    }

    pub const Dir = enum { right, left, up, down };

    pub fn chevron(g: *Gfx, cx: f32, cy: f32, w: f32, h: f32, thick: f32, dir: Dir, col: Color) void {
        const hw = w * 0.5;
        const hh = h * 0.5;
        const pts: [6][2]f32 = switch (dir) {
            .right => .{ .{ -hw, -hh }, .{ -hw + thick, -hh }, .{ hw, 0 }, .{ -hw + thick, hh }, .{ -hw, hh }, .{ hw - thick, 0 } },
            .left => .{ .{ hw, -hh }, .{ hw - thick, -hh }, .{ -hw, 0 }, .{ hw - thick, hh }, .{ hw, hh }, .{ -hw + thick, 0 } },
            .up => .{ .{ -hw, hh }, .{ -hw, hh - thick }, .{ 0, -hh }, .{ hw, hh - thick }, .{ hw, hh }, .{ 0, -hh + thick } },
            .down => .{ .{ -hw, -hh }, .{ -hw, -hh + thick }, .{ 0, hh }, .{ hw, -hh + thick }, .{ hw, -hh }, .{ 0, hh - thick } },
        };
        var v: [6]Vertex = undefined;
        for (0..6) |i| v[i] = vert(cx + pts[i][0], cy + pts[i][1], col);
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2, 0, 2, 5, 5, 2, 3, 5, 3, 4 });
    }

    pub fn diamond(g: *Gfx, cx: f32, cy: f32, rx: f32, ry: f32, col: Color) void {
        const v = [4]Vertex{ vert(cx, cy - ry, col), vert(cx + rx, cy, col), vert(cx, cy + ry, col), vert(cx - rx, cy, col) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    pub fn quad(g: *Gfx, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32, col: Color) void {
        const v = [4]Vertex{ vert(p0[0], p0[1], col), vert(p1[0], p1[1], col), vert(p2[0], p2[1], col), vert(p3[0], p3[1], col) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    pub fn triDir(g: *Gfx, cx: f32, cy: f32, size: f32, dir: Dir, col: Color) void {
        const s = size * 0.5;
        const pts: [3][2]f32 = switch (dir) {
            .up => .{ .{ -s, s * 0.7 }, .{ s, s * 0.7 }, .{ 0, -s * 0.8 } },
            .down => .{ .{ -s, -s * 0.7 }, .{ s, -s * 0.7 }, .{ 0, s * 0.8 } },
            .left => .{ .{ s * 0.7, -s }, .{ s * 0.7, s }, .{ -s * 0.8, 0 } },
            .right => .{ .{ -s * 0.7, -s }, .{ -s * 0.7, s }, .{ s * 0.8, 0 } },
        };
        const v = [3]Vertex{ vert(cx + pts[0][0], cy + pts[0][1], col), vert(cx + pts[1][0], cy + pts[1][1], col), vert(cx + pts[2][0], cy + pts[2][1], col) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2 });
    }

    pub fn triDown(g: *Gfx, cx: f32, cy: f32, size: f32, up: bool, col: Color) void {
        const s = size * 0.5;
        const dy = if (up) -s * 0.6 else s * 0.6;
        const v = [3]Vertex{ vert(cx - s, cy - dy, col), vert(cx + s, cy - dy, col), vert(cx, cy + dy, col) };
        g.batch.push(g.gpa, null, g.state, &v, &.{ 0, 1, 2 });
    }

    pub fn rectOutline(g: *Gfx, x: f32, y: f32, w: f32, h: f32, thick: f32, col: Color) void {
        g.rect(x, y, w, thick, col);
        g.rect(x, y + h - thick, w, thick, col);
        g.rect(x, y + thick, thick, h - 2 * thick, col);
        g.rect(x + w - thick, y + thick, thick, h - 2 * thick, col);
    }

    pub fn round(g: *Gfx, x: f32, y: f32, w: f32, h: f32, radius: f32, col: Color) void {
        const r = @min(radius, @min(w, h) / 2);
        const per = 6;
        var v: [1 + 4 * per]Vertex = undefined;
        var idx: [3 * 4 * per]u32 = undefined;
        v[0] = vert(x + w / 2, y + h / 2, col);
        const cx = [4]f32{ x + w - r, x + r, x + r, x + w - r };
        const cy = [4]f32{ y + h - r, y + h - r, y + r, y + r };
        for (0..4) |q| for (0..per) |i| {
            const a = (@as(f32, @floatFromInt(q)) + @as(f32, @floatFromInt(i)) / (per - 1)) * std.math.pi / 2;
            v[1 + q * per + i] = vert(cx[q] + @cos(a) * r, cy[q] + @sin(a) * r, col);
        };
        for (0..4 * per) |i| {
            const b: u32 = @intCast(i + 1);
            const n: u32 = @intCast((i + 1) % (4 * per) + 1);
            idx[i * 3 ..][0..3].* = .{ 0, b, n };
        }
        g.batch.push(g.gpa, null, g.state, &v, &idx);
    }

    /// Convex polygon with chamfered corner (used for the 4 center Launchpad pads around the diamond).
    /// `corner`: 0=none, 1=BR, 2=BL, 3=TR, 4=TL.
    pub fn chamferPad(g: *Gfx, x: f32, y: f32, w: f32, h: f32, cut: f32, corner: u8, col: Color) void {
        if (corner == 0) {
            g.round(x, y, w, h, @min(w, h) * 0.08, col);
            return;
        }
        var pts: [5][2]f32 = undefined;
        switch (corner) {
            1 => pts = .{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h - cut }, .{ x + w - cut, y + h }, .{ x, y + h } }, // BR
            2 => pts = .{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x + cut, y + h }, .{ x, y + h - cut } }, // BL
            3 => pts = .{ .{ x, y }, .{ x + w - cut, y }, .{ x + w, y + cut }, .{ x + w, y + h }, .{ x, y + h } }, // TR
            4 => pts = .{ .{ x + cut, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h }, .{ x, y + cut } }, // TL
            else => unreachable,
        }
        var v: [6]Vertex = undefined;
        v[0] = vert(x + w / 2, y + h / 2, col);
        for (0..5) |i| v[i + 1] = vert(pts[i][0], pts[i][1], col);
        const idx = [15]u32{ 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5, 0, 5, 1 };
        g.batch.push(g.gpa, null, g.state, &v, &idx);
    }

    pub fn ring(g: *Gfx, cx: f32, cy: f32, r: f32, thick: f32, col: Color) void {
        const segs = 32;
        var v: [2 * (segs + 1)]Vertex = undefined;
        var idx: [6 * segs]u32 = undefined;
        for (0..segs + 1) |i| {
            const a = @as(f32, @floatFromInt(i)) / segs * std.math.tau;
            v[i * 2] = vert(cx + @cos(a) * r, cy + @sin(a) * r, col);
            v[i * 2 + 1] = vert(cx + @cos(a) * (r - thick), cy + @sin(a) * (r - thick), col);
        }
        for (0..segs) |i| {
            const b: u32 = @intCast(i * 2);
            idx[i * 6 ..][0..6].* = .{ b, b + 1, b + 3, b, b + 3, b + 2 };
        }
        g.batch.push(g.gpa, null, g.state, &v, &idx);
    }

    pub fn disc(g: *Gfx, cx: f32, cy: f32, r: f32, col: Color) void {
        g.ring(cx, cy, r, r, col);
    }

    fn fontIndex(size: u16) usize {
        for (font_sizes, 0..) |s, i| if (s >= size) return i;
        return font_sizes.len - 1;
    }

    fn textEntry(g: *Gfx, s: []const u8, size: u16, col_in: Color) ?*TextEntry {
        if (s.len == 0) return null;
        const col = col_in.alpha(255);
        var hasher = std.hash.Wyhash.init(@as(u64, col.r) << 24 | @as(u64, col.g) << 16 | @as(u64, col.b) << 8 | 255);
        hasher.update(s);
        const key: TextKey = .{ .hash = hasher.final(), .size = size };
        const gop = g.text_cache.getOrPut(g.gpa, key) catch return null;
        if (gop.found_existing) {
            gop.value_ptr.frame = g.frame;
            return gop.value_ptr;
        }
        const font = g.fonts[fontIndex(size)] orelse {
            _ = g.text_cache.remove(key);
            return null;
        };
        const blended = c.TTF_RenderText_Blended(font, s.ptr, s.len, .{ .r = col.r, .g = col.g, .b = col.b, .a = 255 });
        defer c.SDL_DestroySurface(blended);
        const surf = if (blended != null) c.SDL_ConvertSurface(blended, c.SDL_PIXELFORMAT_RGBA32) else null;
        defer c.SDL_DestroySurface(surf);
        const tex = if (surf != null) g.textureFromPixels(@ptrCast(surf.*.pixels), surf.*.w, surf.*.h, @intCast(surf.*.pitch)) else null;
        if (tex == null) {
            _ = g.text_cache.remove(key);
            return null;
        }
        gop.value_ptr.* = .{ .tex = tex.?, .w = @floatFromInt(surf.*.w), .h = @floatFromInt(surf.*.h), .frame = g.frame };
        return gop.value_ptr;
    }

    fn drawTextTex(g: *Gfx, t: *Texture, x: f32, y: f32, w: f32, h: f32, a: u8) void {
        const u_end = w / t.w;
        const col = [4]u8{ 255, 255, 255, a };
        const v = [4]Vertex{
            .{ .x = x, .y = y, .u = 0, .v = 0, .col = col },
            .{ .x = x + w, .y = y, .u = u_end, .v = 0, .col = col },
            .{ .x = x + w, .y = y + h, .u = u_end, .v = 1, .col = col },
            .{ .x = x, .y = y + h, .u = 0, .v = 1, .col = col },
        };
        g.batch.push(g.gpa, t, g.state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    pub fn text(g: *Gfx, s: []const u8, x: f32, y: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawTextTex(e.tex, @round(x), @round(y), e.w, e.h, col.a);
    }

    pub fn textCentered(g: *Gfx, s: []const u8, cx: f32, cy: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawTextTex(e.tex, @round(cx - e.w / 2), @round(cy - e.h / 2), e.w, e.h, col.a);
    }

    pub fn textClip(g: *Gfx, s: []const u8, x: f32, y: f32, max_w: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawTextTex(e.tex, @round(x), @round(y), @min(e.w, max_w), e.h, col.a);
    }

    pub fn textRight(g: *Gfx, s: []const u8, right: f32, y: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawTextTex(e.tex, @round(right - e.w), @round(y), e.w, e.h, col.a);
    }

    pub fn measure(g: *Gfx, s: []const u8, size: u16) f32 {
        const e = g.textEntry(s, size, white) orelse return 0;
        return e.w;
    }

    pub fn fmt(g: *Gfx, x: f32, y: f32, size: u16, col: Color, comptime f: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, f, args) catch return;
        g.text(s, x, y, size, col);
    }

    pub fn fmtCentered(g: *Gfx, cx: f32, cy: f32, size: u16, col: Color, comptime f: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, f, args) catch return;
        g.textCentered(s, cx, cy, size, col);
    }
};
