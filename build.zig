const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("third_party"));
    translate.addIncludePath(b.path("third_party/nfd"));
    translate.addIncludePath(b.path("src"));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate.createModule() },
        },
    });
    mod.addCSourceFile(.{ .file = b.path("third_party/impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    mod.addIncludePath(b.path("third_party"));
    mod.addIncludePath(b.path("third_party/nfd"));
    mod.addIncludePath(b.path("src/render"));
    mod.addIncludePath(b.path("src/midi"));
    mod.addAnonymousImport("font_medium", .{ .root_source_file = b.path("assets/fonts/SUITE-Medium.ttf") });
    mod.addAnonymousImport("font_heavy", .{ .root_source_file = b.path("assets/fonts/SUITE-ExtraBold.ttf") });

    const shaders = [_][]const u8{ "sprite.vert", "sprite.frag" };
    for (shaders) |name| {
        const naga = b.addSystemCommand(&.{ "naga", "--keep-coordinate-space" });
        naga.addFileArg(b.path(b.fmt("src/render/shaders/{s}.wgsl", .{name})));
        var shader = naga.addOutputFileArg(b.fmt("{s}.spv", .{name}));
        if (os == .windows or os == .macos) {
            const cross = b.addSystemCommand(&.{"spirv-cross"});
            cross.addFileArg(shader);
            if (os == .windows)
                cross.addArgs(&.{ "--hlsl", "--shader-model", "50" })
            else
                cross.addArgs(&.{ "--msl", "--msl-version", "20000", "--msl-decoration-binding" });
            cross.addArg("--output");
            shader = cross.addOutputFileArg(b.fmt("{s}.src", .{name}));
        }
        mod.addAnonymousImport(name, .{ .root_source_file = shader });
    }

    if (os == .macos) {
        mod.addCSourceFile(.{ .file = b.path("src/render/render_backend.m"), .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" } });
        mod.addCSourceFile(.{ .file = b.path("src/midi/midi_macos.c"), .flags = &.{"-fno-sanitize=undefined"} });
        mod.addCSourceFile(.{ .file = b.path("third_party/nfd/nfd_cocoa.m"), .flags = &.{ "-DNFD_MACOS_ALLOWEDCONTENTTYPES=1", "-fno-sanitize=undefined" } });
        mod.linkFramework("Metal", .{});
        mod.linkFramework("QuartzCore", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("CoreMIDI", .{});
        mod.linkFramework("AppKit", .{});
        mod.linkFramework("UniformTypeIdentifiers", .{});
    } else {
        mod.addCSourceFile(.{ .file = b.path("src/render/render_backend.c"), .flags = &.{"-fno-sanitize=undefined"} });
    }

    if (os == .windows) {
        mod.addCSourceFile(.{ .file = b.path("src/midi/midi_win.c"), .flags = &.{"-fno-sanitize=undefined"} });
        mod.addCSourceFile(.{ .file = b.path("third_party/nfd/nfd_win.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined" } });
        mod.linkSystemLibrary("d3d11", .{});
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("dxguid", .{});
        mod.linkSystemLibrary("winmm", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("uuid", .{});
        mod.linkSystemLibrary("shell32", .{});

        const prefix = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=prefix", "sdl3" }), "\r\n");
        const include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) };
        mod.addIncludePath(include);
        translate.addIncludePath(include);
        for ([_][]const u8{ "portaudio", "SDL3", "SDL3_ttf", "archive" }) |lib|
            mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", b.fmt("lib{s}.dll.a", .{lib}) }) });
    } else if (os == .linux) {
        mod.addCSourceFile(.{ .file = b.path("third_party/nfd/nfd_portal.cpp"), .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined", "-DNFD_PORTAL", "-DNFD_X11" } });
        mod.linkSystemLibrary("vulkan", .{ .use_pkg_config = .force });
        mod.linkSystemLibrary("alsa", .{ .use_pkg_config = .force });
        mod.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .force });
        translate.linkSystemLibrary("alsa", .{});
    } else if (os == .macos) {
        const portaudio = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=prefix", "portaudio-2.0" }), "\n");
        const include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ portaudio, "include" }) };
        mod.addIncludePath(include);
        translate.addIncludePath(include);
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ portaudio, "lib" }) });
        mod.linkSystemLibrary("portaudio", .{ .use_pkg_config = .no });
    } else {
        mod.linkSystemLibrary("portaudio-2.0", .{ .use_pkg_config = .force });
        translate.linkSystemLibrary("portaudio-2.0", .{});
    }

    if (os != .windows) {
        for ([_][]const u8{ "sdl3-ttf", "libarchive" }) |lib| {
            mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
            translate.linkSystemLibrary(lib, .{});
        }
    }

    const exe = b.addExecutable(.{ .name = "unipad-zig", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run unipad-zig").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
