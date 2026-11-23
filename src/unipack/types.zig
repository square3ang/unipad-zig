//! Shared pure-Zig UniPack data types (usable on both desktop and wasm32-freestanding).

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

pub const VirtualFile = struct {
    /// Forward-slash relative path within the pack root.
    rel_path: []const u8,
    bytes: []const u8,
};
