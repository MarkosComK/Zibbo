const std = @import("std");
const types = @import("types.zig");
const PriceLevel = types.PriceLevel;
const Side = types.Side;

// Maintains an aggregated, sorted view of price levels for one side of the
// book. Stores (price, size) aggregates only - never slot indices into the
// slab - so it never needs to know about compact() (see docs/ for the QD
// comparison: this is the same idea as QD's array-backed RecordBuffer
// storage, at price-level granularity instead of tick granularity).
pub const PriceLevelIndex = struct {
    const MAX_LEVELS = 1024;

    levels: [MAX_LEVELS]PriceLevel,
    count: usize,
    side: Side,

    pub fn init(side: Side) PriceLevelIndex {
        return .{
            .levels = undefined,
            .count = 0,
            .side = side,
        };
    }

    // Applies a size change at `price`, creating the level if it doesn't
    // exist yet. Positive delta = size added (new order or size increase),
    // negative delta = size removed (execution or size decrease).
    //
    // count/implied_size are left at 0 for every level: this function's
    // signature (price, size_delta, time) can't tell a brand-new order
    // apart from an existing order's size changing, so there isn't enough
    // information here to track per-level order counts correctly. Left as
    // a known gap rather than guessed at.
    pub fn update(self: *PriceLevelIndex, price: i64, size_delta: i64, time: i64) void {
        const result = self.findIndex(price);
        if (result.found) {
            self.levels[result.index].size += size_delta;
            self.levels[result.index].time = time;
            if (self.levels[result.index].size <= 0) {
                self.removeAt(result.index);
            }
            return;
        }
        self.insertAt(result.index, .{
            .price = price,
            .size = size_delta,
            .implied_size = 0,
            .count = 0,
            .time = time,
        });
    }

    // Removes `size_delta` from the level at `price`, dropping the level
    // entirely once its size reaches zero. No-op if the price isn't tracked.
    pub fn remove(self: *PriceLevelIndex, price: i64, size_delta: i64) void {
        const result = self.findIndex(price);
        if (!result.found) return;
        self.levels[result.index].size -= size_delta;
        if (self.levels[result.index].size <= 0) {
            self.removeAt(result.index);
        }
    }

    pub fn best(self: *const PriceLevelIndex) ?PriceLevel {
        if (self.count == 0) return null;
        return self.levels[0];
    }

    // Copies up to `n` levels (and no more than `out` can hold) into `out`,
    // best price first. Returns how many were written - caller-owned
    // buffer, no allocation here.
    pub fn topN(self: *const PriceLevelIndex, n: usize, out: []PriceLevel) usize {
        const limit = @min(n, @min(self.count, out.len));
        for (0..limit) |i| out[i] = self.levels[i];
        return limit;
    }

    const FindResult = struct { index: usize, found: bool };

    // Binary search over levels[0..count]. Returns the matching index when
    // `price` is already tracked, otherwise the index it should be inserted
    // at to keep the array sorted for this side.
    fn findIndex(self: *const PriceLevelIndex, price: i64) FindResult {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_price = self.levels[mid].price;
            if (mid_price == price) return .{ .index = mid, .found = true };
            if (self.isBetter(mid_price, price)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return .{ .index = lo, .found = false };
    }

    // Bids sort descending (best/highest price first); asks sort ascending
    // (best/lowest price first). "isBetter(a, b)" means "a belongs before b".
    fn isBetter(self: *const PriceLevelIndex, a: i64, b: i64) bool {
        return switch (self.side) {
            .Buy => a > b,
            .Sell => a < b,
        };
    }

    fn insertAt(self: *PriceLevelIndex, index: usize, level: PriceLevel) void {
        std.debug.assert(self.count < MAX_LEVELS);
        var i = self.count;
        while (i > index) : (i -= 1) {
            self.levels[i] = self.levels[i - 1];
        }
        self.levels[index] = level;
        self.count += 1;
    }

    fn removeAt(self: *PriceLevelIndex, index: usize) void {
        var i = index;
        while (i + 1 < self.count) : (i += 1) {
            self.levels[i] = self.levels[i + 1];
        }
        self.count -= 1;
    }
};

test "init starts empty" {
    const idx = PriceLevelIndex.init(.Buy);
    try std.testing.expectEqual(@as(usize, 0), idx.count);
    try std.testing.expect(idx.best() == null);
}

test "bids sort descending, best is highest price" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);
    idx.update(10500, 3, 2);
    idx.update(9500, 7, 3);

    try std.testing.expectEqual(@as(usize, 3), idx.count);
    try std.testing.expectEqual(@as(i64, 10500), idx.levels[0].price);
    try std.testing.expectEqual(@as(i64, 10000), idx.levels[1].price);
    try std.testing.expectEqual(@as(i64, 9500), idx.levels[2].price);
    try std.testing.expectEqual(@as(i64, 10500), idx.best().?.price);
}

test "asks sort ascending, best is lowest price" {
    var idx = PriceLevelIndex.init(.Sell);
    idx.update(10000, 5, 1);
    idx.update(10500, 3, 2);
    idx.update(9500, 7, 3);

    try std.testing.expectEqual(@as(i64, 9500), idx.levels[0].price);
    try std.testing.expectEqual(@as(i64, 10000), idx.levels[1].price);
    try std.testing.expectEqual(@as(i64, 10500), idx.levels[2].price);
    try std.testing.expectEqual(@as(i64, 9500), idx.best().?.price);
}

test "update on existing price accumulates size" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);
    idx.update(10000, 3, 2);

    try std.testing.expectEqual(@as(usize, 1), idx.count);
    try std.testing.expectEqual(@as(i64, 8), idx.levels[0].size);
    try std.testing.expectEqual(@as(i64, 2), idx.levels[0].time);
}

test "update draining size to zero removes the level" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);
    idx.update(10500, 3, 2);
    idx.update(10000, -5, 3);

    try std.testing.expectEqual(@as(usize, 1), idx.count);
    try std.testing.expectEqual(@as(i64, 10500), idx.levels[0].price);
}

test "remove decrements size and drops level at zero" {
    var idx = PriceLevelIndex.init(.Sell);
    idx.update(10000, 10, 1);

    idx.remove(10000, 4);
    try std.testing.expectEqual(@as(usize, 1), idx.count);
    try std.testing.expectEqual(@as(i64, 6), idx.levels[0].size);

    idx.remove(10000, 6);
    try std.testing.expectEqual(@as(usize, 0), idx.count);
    try std.testing.expect(idx.best() == null);
}

test "remove on untracked price is a no-op" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);
    idx.remove(9999, 100);
    try std.testing.expectEqual(@as(usize, 1), idx.count);
}

test "topN copies best-first up to the smaller of n and out.len" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);
    idx.update(10500, 3, 2);
    idx.update(9500, 7, 3);
    idx.update(11000, 1, 4);

    var out: [2]PriceLevel = undefined;
    const written = idx.topN(2, &out);

    try std.testing.expectEqual(@as(usize, 2), written);
    try std.testing.expectEqual(@as(i64, 11000), out[0].price);
    try std.testing.expectEqual(@as(i64, 10500), out[1].price);
}

test "topN is bounded by available levels, not just n" {
    var idx = PriceLevelIndex.init(.Buy);
    idx.update(10000, 5, 1);

    var out: [5]PriceLevel = undefined;
    const written = idx.topN(5, &out);

    try std.testing.expectEqual(@as(usize, 1), written);
}
