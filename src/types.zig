const std = @import("std");

pub const Side = enum(u8) { Buy, Sell };

pub const OrderAction = enum(u8) {
    New,
    Replace,
    Modify,
    Delete,
    Partial,
    Execute,
    Trade,
    Bust,
};

pub const OrderEntry = extern struct {
    order_id:    u64,
    price:       i64,
    size:        i64,
    trade_id:    u64,
    trade_price: i64,
    trade_size:  i64,
    time:        i64,
    side:        Side,
    action:      OrderAction,
    _pad:        [6]u8 = [_]u8{0} ** 6,
};

comptime {
    if (@sizeOf(OrderEntry) != 64)
        @compileError("OrderEntry must be exactly 64 bytes (one cache line)");
}

pub const PriceLevel = struct {
    price:        i64,
    size:         i64,
    implied_size: i64,
    count:        u32,
    time:         i64,
};

test "OrderEntry is exactly 64 bytes" {
    try std.testing.expectEqual(64, @sizeOf(OrderEntry));
}

test "OrderEntry field offsets" {
    try std.testing.expectEqual(0,  @offsetOf(OrderEntry, "order_id"));
    try std.testing.expectEqual(8,  @offsetOf(OrderEntry, "price"));
    try std.testing.expectEqual(16, @offsetOf(OrderEntry, "size"));
    try std.testing.expectEqual(24, @offsetOf(OrderEntry, "trade_id"));
    try std.testing.expectEqual(32, @offsetOf(OrderEntry, "trade_price"));
    try std.testing.expectEqual(40, @offsetOf(OrderEntry, "trade_size"));
    try std.testing.expectEqual(48, @offsetOf(OrderEntry, "time"));
    try std.testing.expectEqual(56, @offsetOf(OrderEntry, "side"));
    try std.testing.expectEqual(57, @offsetOf(OrderEntry, "action"));
    try std.testing.expectEqual(58, @offsetOf(OrderEntry, "_pad"));
}

test "Side enum values" {
    try std.testing.expectEqual(0, @intFromEnum(Side.Buy));
    try std.testing.expectEqual(1, @intFromEnum(Side.Sell));
}

test "OrderAction enum values" {
    try std.testing.expectEqual(0, @intFromEnum(OrderAction.New));
    try std.testing.expectEqual(7, @intFromEnum(OrderAction.Bust));
}
