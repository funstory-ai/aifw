// Minimal C runtime shims for wasm32-freestanding linking
// Only compiled when imported by freestanding targets.
const std = @import("std");

pub export fn strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}
