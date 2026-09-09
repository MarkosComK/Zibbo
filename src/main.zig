const std = @import("std");

pub fn main() !void {}

// Zig only collects tests from files reachable via @import from the root
// file passed to `zig test`/`addTest`. Without this, `zig build test` was
// silently running zero tests - main.zig had no imports at all.
test {
    _ = @import("types.zig");
    _ = @import("price_index.zig");
}
