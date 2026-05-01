# Claude Code Bootstrap — orderbook-zig

## What This Project Is

A production-grade orderbook in Zig, benchmarked against Java (dxFeed/QD reference implementation).
This is also a learning project — every design decision teaches a specific Zig or systems concept.
This file is fully self-contained. You do not need to read any other file before starting.

---

## Collaboration Style

This is a teach-first, implement-second project. Before writing any code for a step:

1. **Explain** what we're about to build — the concept, why it matters, and what Zig/systems idea it teaches.
2. **Wait** for the user to confirm they understand before touching any file.
3. **Implement** together, one step at a time. Never jump ahead.

If the user says "ok" or "got it" or equivalent — that is the green light to implement. If they ask a follow-up question, answer it fully before writing code. Never skip the explanation phase, even for simple steps.

---

## What You Will Learn

| Component | Zig concept | Systems concept |
|-----------|-------------|-----------------|
| `OrderEntry` extern struct | `@sizeOf`, struct layout, padding | Cache line alignment, ABI |
| Arena/slab allocator | `std.heap.ArenaAllocator` | GC vs manual memory, fragmentation |
| Packed bitset | `@bitSizeOf`, bit manipulation | Space efficiency vs bool arrays |
| Open-addressing hash table | `std.AutoHashMap` | Why Java HashMap is expensive |
| `PriceLevelIndex` | Sorted arrays, binary search | Why a tree is avoidable |
| `/proc/self/status` reader | file I/O, string parsing | Linux RSS measurement |
| Comptime assertions | `comptime`, `@compileError` | Catching regressions at compile time |
| C ABI export | `export fn`, `extern struct` | Interop, how JNA/JNI work |
| JSON output | `std.json.stringify` | Data pipeline design |

---

## Java Reference (What We're Benchmarking Against)

Key Java data structures:
- `ArrayList<OrderBookEntry>` — slot array, O(1) by index
- `IndexedSet<Long, OrderBookEntry>` — open-addressing hash map, orderId → entry
- `ReusableIdProvider` — free-list of internal slot indices (NOT market order IDs)
- `CheckedTreeList<Order>` — balanced tree for price-sorted iteration

**Important:** Java's `ReusableIdProvider` manages internal *storage slot indices*, not market-issued order IDs.
The `id_map` maps `market_order_id (u64) → slot_index (u16)`. These are two different ID spaces. Keep them separate.

### Target Metrics

| Metric | Java | Zig target |
|--------|------|------------|
| Bytes/order (logical) | ~128–160 (object header + GC) | ~64 (one cache line) |
| HashMap overhead/entry | ~48 bytes (Entry + Long boxing) | ~10 bytes (open-addressing) |
| Occupancy tracking | GC implicit | 1 bit/slot in bitset |
| Compaction trigger | `unused > max(size>>2, 25)` | same |
| Price level query (best) | O(log N) tree traversal | O(1) array head |
| GC pauses during load | yes | none |

---

## Architecture

```
                    ┌─────────────────────────────────┐
                    │           OrderBook              │
                    │  slab: []OrderEntry  ← arena     │
                    │  free_list: []u16                │
                    │  id_map: HashMap(u64→u16)        │
                    │  bid_index: PriceLevelIndex      │
                    │  ask_index: PriceLevelIndex      │
                    └─────────────────────────────────┘
                              │           │
                    ┌─────────┘           └──────────┐
                    ▼                                ▼
           PriceLevelIndex(Buy)           PriceLevelIndex(Sell)
           sorted desc by price           sorted asc by price
```

---

## Your Dependency: Zib

This project depends on **Zib** — a Zig utility library by the same author.

- GitHub: `https://github.com/MarkosComK/Zib`
- Provides: `math`, `str`, `char`, `cast` modules

### Wire Zib via Zig package manager

```zig
// build.zig.zon
.{
    .name = "orderbook-zig",
    .version = "0.1.0",
    .dependencies = .{
        .zib = .{
            .url = "https://github.com/MarkosComK/Zib/archive/main.tar.gz",
            .hash = "<run zig fetch --save to populate this>",
        },
    },
    .paths = .{""},
}
```

```zig
// build.zig — after building the exe:
const zib_dep = b.dependency("zib", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zib", zib_dep.module("zib"));
```

First command after cloning: `zig fetch --save https://github.com/MarkosComK/Zib/archive/main.tar.gz`
This populates the hash in `build.zig.zon` automatically.

---

## Project File Layout

```
orderbook-zig/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig            # benchmark harness + JSON output
│   ├── orderbook.zig       # core: slab + free_list + id_map + price_index
│   ├── price_index.zig     # PriceLevelIndex: sorted price-level view
│   ├── feed.zig            # synthetic order feed generator
│   ├── memory.zig          # /proc/self/status RSS reader + MemoryStats
│   └── types.zig           # OrderEntry, PriceLevel, Side, OrderAction
└── scripts/
    ├── compare.py          # matplotlib graphs
    ├── run_bench.sh        # runs both Zig + Java, feeds compare.py
    └── OrderBookBench.java # Java benchmark (standalone, no Maven)
```

---

## Implementation Notes (discoveries made during build)

- **`executed_size` removed from `OrderEntry`:** The original spec listed 8 × 8-byte fields which totals 72 bytes before enums/pad. `executed_size` was dropped — it's computable as `original_size - size`. The comptime assertion caught this immediately.
- **macOS test target:** `zig test src/file.zig` fails on macOS with this dev build due to SDK linker issues. Use `zig test src/file.zig -target aarch64-macos` instead.
- **Zib cannot be wired via `zig fetch --save`:** Zib has no `build.zig.zon`, so the package manager can't auto-name it. Zib integration will be handled manually when a step actually needs it. `types.zig` and likely several other files don't need it at all.
- **Docs branch:** Learning Q&A and explanations live in the `docs` branch under `docs/`. One file per step. Add to it after each step's explanation and any notable questions.

---

## Build Order — Follow Strictly

Write a `test` block in each file before moving to the next.

---

### Step 1: `src/types.zig`

`OrderEntry` must be exactly **64 bytes** (one cache line). The comptime assertion is your regression guard.

```zig
const std = @import("std");

pub const Side = enum(u8) { Buy, Sell };

pub const OrderAction = enum(u8) {
    New, Replace, Modify, Delete, Partial, Execute, Trade, Bust
};

// extern struct: Zig lays out fields with no implicit padding.
// Java equivalent: ~128-160 bytes with object header and GC metadata.
pub const OrderEntry = extern struct {
    order_id:      u64,
    price:         i64,   // fixed-point: actual_price * 10^8
    size:          i64,
    executed_size: i64,
    trade_id:      u64,
    trade_price:   i64,
    trade_size:    i64,
    time:          i64,
    side:          Side,
    action:        OrderAction,
    _pad:          [6]u8 = [_]u8{0} ** 6,
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
```

---

### Step 2: `src/price_index.zig`

The slab stores orders in insertion order. Without this index, answering "top 5 bid prices?" requires scanning all N slots — O(N log N). The number of *distinct price levels* is much smaller than the number of *orders* (e.g. 10,000 orders but only 200 prices), so a sorted array of aggregates is faster than a tree for P < ~500 due to cache locality.

- Bids: sorted **descending** by price (best bid = index 0)
- Asks: sorted **ascending** by price (best ask = index 0)

```zig
const std = @import("std");
const types = @import("types.zig");
const PriceLevel = types.PriceLevel;
const Side = types.Side;

pub const PriceLevelIndex = struct {
    const MAX_LEVELS = 1024;

    levels: [MAX_LEVELS]PriceLevel,
    count:  usize,
    side:   Side,

    pub fn init(side: Side) PriceLevelIndex
    pub fn update(self: *PriceLevelIndex, price: i64, size_delta: i64, time: i64) void
    pub fn remove(self: *PriceLevelIndex, price: i64, size_delta: i64) void
    pub fn best(self: *const PriceLevelIndex) ?PriceLevel   // first element or null
    pub fn topN(self: *const PriceLevelIndex, n: usize, out: []PriceLevel) usize
};
```

`update()` logic:
- Binary search for `price` in `levels[0..count]`
- If found: add `size_delta` to `levels[i].size`; if size reaches 0, shift array left
- If not found: find insertion point, shift right, insert new `PriceLevel`

`update()` is called from every orderbook operation:
- `addOrder` → `update(price, +size, time)`
- `executeOrder` → `update(price, -size, time)` or `remove` if size hits 0
- `modifyOrder` → `update(price, size_delta, time)`
- `deleteOrder` → `remove(price, size)`

**Note:** `PriceLevelIndex` stores price/size aggregates, NOT slot indices. It does NOT need rebuilding after `compact()`.

---

### Step 3: `src/memory.zig`

```zig
pub const MemoryStats = struct {
    slab_capacity_bytes: usize,   // slab_len * @sizeOf(OrderEntry)
    slab_used_bytes:     usize,   // active_count * @sizeOf(OrderEntry)
    id_map_bytes:        usize,   // estimated: id_map.count() * (8+2+overhead)
    free_list_bytes:     usize,   // free_top * @sizeOf(u16)
    occupied_bits_bytes: usize,   // slab_len / 8
    price_index_bytes:   usize,   // 2 * MAX_LEVELS * @sizeOf(PriceLevel)
    total_logical_bytes: usize,
    active_orders:       usize,
    utilization_pct:     f32,
};

// Linux only: reads /proc/self/status, parses VmRSS line.
// On macOS this will fail — use logical stats only during dev on Mac.
pub fn readRssKb() !usize
```

Call `readRssKb()` at these checkpoints in the benchmark:
1. After `OrderBook.init()` (baseline)
2. After loading 1k / 10k / 100k orders
3. After `compact()`
4. After all orders executed/deleted

---

### Step 4: `src/orderbook.zig`

**Two ID spaces — keep them separate:**
- `market_order_id` (`u64`) — arrives from the feed
- `slot_index` (`u16`) — internal slab position managed by `free_list`
- `id_map`: `HashMap(u64 → u16)` bridges them

**Why not a fixed `[65536]OrderEntry`?** At 64 bytes/entry that is 4 MB per book, pre-allocated regardless of actual load. With 10 symbols: 40 MB before a single order arrives. Use a growing arena slab instead.

**Why not `GeneralPurposeAllocator` for benchmarks?** The GPA has ~32 bytes/allocation of metadata overhead for use-after-free detection. Use GPA during development, `ArenaAllocator` for benchmarks.

```zig
const std = @import("std");
const types = @import("types.zig");
const PriceLevelIndex = @import("price_index.zig").PriceLevelIndex;
const memory = @import("memory.zig");

pub const OrderBook = struct {
    slab:         []types.OrderEntry,
    slab_len:     usize,
    active_count: usize,

    free_list:    []u16,
    free_top:     usize,

    occupied:     []u8,           // bitset: bit i = slot i is active; 8x more compact than []bool

    id_map:       std.AutoHashMap(u64, u16),

    bid_index:    PriceLevelIndex,
    ask_index:    PriceLevelIndex,

    symbol:       []const u8,
    arena:        std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, symbol: []const u8, initial_capacity: usize) !OrderBook
    pub fn deinit(self: *OrderBook) void

    // Internal slab helpers
    fn allocSlot(self: *OrderBook) !u16
    fn freeSlot(self: *OrderBook, idx: u16) void
    fn setBit(self: *OrderBook, idx: u16) void
    fn clearBit(self: *OrderBook, idx: u16) void
    fn testBit(self: *const OrderBook, idx: u16) bool

    // Operations — each follows: validate → mutate slab → update price index
    pub fn addOrder(self: *OrderBook, entry: types.OrderEntry) !void
    pub fn replaceOrder(self: *OrderBook, order_id: u64, new_price: i64, new_size: i64) !void
    pub fn modifyOrder(self: *OrderBook, order_id: u64, new_size: i64) !void
    pub fn executeOrder(self: *OrderBook, order_id: u64, size: i64, trade_price: i64, trade_id: u64) !void
    pub fn partialExecute(self: *OrderBook, order_id: u64, remaining_size: i64) !void
    pub fn deleteOrder(self: *OrderBook, order_id: u64) !void
    pub fn cancelOrder(self: *OrderBook, order_id: u64) !void  // alias for deleteOrder

    pub fn getBestBid(self: *const OrderBook) ?types.PriceLevel
    pub fn getBestAsk(self: *const OrderBook) ?types.PriceLevel
    pub fn getPriceLevels(self: *const OrderBook, side: types.Side, depth: usize, out: []types.PriceLevel) usize

    pub fn compact(self: *OrderBook) void
    pub fn getMemoryStats(self: *const OrderBook) memory.MemoryStats
};
```

**Compaction trigger** (mirrors Java policy exactly):
```zig
fn unusedCount(self: *const OrderBook) usize {
    return self.slab_len - self.active_count;
}

fn shouldCompact(self: *const OrderBook) bool {
    const threshold = @max(self.active_count >> 2, 25);
    return self.unusedCount() > threshold;
}
```

**`addOrder` pseudocode:**
```
1. allocSlot() → idx      (pop free_list or grow slab by doubling)
2. slab[idx] = entry
3. setBit(idx)
4. id_map.put(entry.order_id, idx)
5. active_count += 1
6. index_for(entry.side).update(entry.price, +entry.size, entry.time)
7. if shouldCompact() → compact()
```

**`compact()` pseudocode:**
```
write_cursor = 0
for i in 0..slab_len:
    if testBit(i):
        if i != write_cursor:
            slab[write_cursor] = slab[i]
            clearBit(i)
            setBit(write_cursor)
        write_cursor += 1
slab_len = write_cursor
free_top = 0
rebuild id_map by iterating active slots 0..slab_len
// PriceLevelIndex does NOT need rebuilding — it's index-independent
```

---

### Step 5: `src/feed.zig`

```zig
pub const FeedConfig = struct {
    num_symbols:       usize = 10,
    orders_per_symbol: usize = 10_000,
    price_levels:      usize = 200,
    price_tick:        i64   = 100,
    size_range:        struct { min: i64, max: i64 } = .{ .min = 1, .max = 1000 },
    cancel_rate:       f32   = 0.30,
    execute_rate:      f32   = 0.40,
    partial_rate:      f32   = 0.10,
    seed:              u64   = 42,
};

pub const FeedStats = struct {
    total_adds:     u64,
    total_executes: u64,
    total_cancels:  u64,
    total_modifies: u64,
    compactions:    u64,
    elapsed_ns:     u64,
};

pub fn runFeed(books: []OrderBook, config: FeedConfig, allocator: std.mem.Allocator) !FeedStats
```

Order lifecycle per entry:
1. `addOrder` (always)
2. Random subset gets `modifyOrder`
3. One of: `executeOrder`, `partialExecute` → `cancelOrder`, or just `cancelOrder`

Use `std.Random.DefaultPrng` seeded with `config.seed` for reproducibility.

---

### Step 6: `src/main.zig`

Benchmark harness. RSS checkpoints at: after `init`, after 1k/10k/100k orders, after `compact`, after all cleared.

JSON output schema (must match Java output for `compare.py`):
```json
{
  "implementation": "zig",
  "books": [
    {
      "symbol": "SYM0",
      "active_orders": 10000,
      "slab_capacity_bytes": 655360,
      "slab_used_bytes": 640000,
      "id_map_bytes": 87040,
      "total_logical_bytes": 663552,
      "rss_kb": 1024,
      "bytes_per_order": 66.36,
      "utilization_pct": 0.97
    }
  ],
  "aggregate": {
    "total_logical_bytes": 0,
    "total_rss_kb": 0,
    "avg_utilization_pct": 0.0
  }
}
```

Build flags:
```bash
zig build -Doptimize=ReleaseFast      # benchmark
zig build -Doptimize=Debug            # development
zig build test                        # tests
./zig-out/bin/orderbook-bench > results_zig.json
```

---

### Step 7: `scripts/OrderBookBench.java`

Standalone Java benchmark. No Maven. Outputs same JSON schema as Zig.

```java
// Compile: javac scripts/OrderBookBench.java -d scripts/
// Run:     java -XX:+UseSerialGC -Xms64m -Xmx512m -cp scripts/ OrderBookBench > results_java.json

import java.lang.management.*;
import java.util.*;

public class OrderBookBench {
    static long heapUsed() {
        MemoryMXBean m = ManagementFactory.getMemoryMXBean();
        return m.getHeapMemoryUsage().getUsed();
    }

    public static void main(String[] args) throws Exception {
        int ordersPerSymbol = 10_000;
        int numSymbols = 10;

        List<Map<String, Object>> books = new ArrayList<>();

        for (int s = 0; s < numSymbols; s++) {
            System.gc(); Thread.sleep(50);
            long before = heapUsed();

            HashMap<Long, long[]> book = new HashMap<>(ordersPerSymbol * 2);
            for (long i = 0; i < ordersPerSymbol; i++) {
                // long[] = {price, size, executedSize, tradePrice, tradeSize, time, side, action}
                book.put(i, new long[]{10000L + i % 200, 100L, 0L, 0L, 0L,
                    System.currentTimeMillis(), 0L, 0L});
            }

            System.gc(); Thread.sleep(50);
            long after = heapUsed();

            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("symbol", "SYM" + s);
            entry.put("active_orders", book.size());
            entry.put("heap_used_bytes", after - before);
            entry.put("bytes_per_order", (after - before) / (double) ordersPerSymbol);
            books.add(entry);
        }

        System.out.println("{\"implementation\":\"java\",\"books\":[");
        for (int i = 0; i < books.size(); i++) {
            Map<String, Object> b = books.get(i);
            System.out.printf(
                "{\"symbol\":\"%s\",\"active_orders\":%d,\"heap_used_bytes\":%d,\"bytes_per_order\":%.2f}%s%n",
                b.get("symbol"), b.get("active_orders"), b.get("heap_used_bytes"),
                b.get("bytes_per_order"), i < books.size() - 1 ? "," : ""
            );
        }
        System.out.println("]}");
    }
}
```

---

### Step 8: `scripts/compare.py`

```python
# Requirements: pip install matplotlib numpy
# Usage: python3 scripts/compare.py results_zig.json results_java.json

import json, sys
import matplotlib.pyplot as plt
import numpy as np

zig  = json.load(open(sys.argv[1]))
java = json.load(open(sys.argv[2]))

zig_books  = zig["books"]
java_books = java["books"]
symbols    = [b["symbol"] for b in zig_books]
x          = np.arange(len(symbols))
width      = 0.35

fig, axes = plt.subplots(2, 3, figsize=(16, 10))
fig.suptitle("Zig vs Java Orderbook Memory Comparison")

# Graph 1: bytes/order side by side
ax = axes[0, 0]
zig_bpo  = [b["bytes_per_order"] for b in zig_books]
java_bpo = [b["bytes_per_order"] for b in java_books]
ax.bar(x - width/2, zig_bpo,  width, label="Zig",  color="steelblue")
ax.bar(x + width/2, java_bpo, width, label="Java", color="coral")
ax.set_title("Bytes per Order")
ax.set_xticks(x); ax.set_xticklabels(symbols, rotation=45)
ax.legend()

# Graph 2: total logical bytes
ax = axes[0, 1]
zig_total  = [b["total_logical_bytes"] / 1024 for b in zig_books]
java_total = [b["heap_used_bytes"] / 1024 for b in java_books]
ax.bar(x - width/2, zig_total,  width, label="Zig",  color="steelblue")
ax.bar(x + width/2, java_total, width, label="Java", color="coral")
ax.set_title("Total Memory (KB)")
ax.set_xticks(x); ax.set_xticklabels(symbols, rotation=45)
ax.legend()

# Graph 3: Zig utilization %
ax = axes[0, 2]
zig_util = [b["utilization_pct"] * 100 for b in zig_books]
ax.bar(symbols, zig_util, color="steelblue")
ax.set_title("Zig Slab Utilization %")
ax.set_ylim(0, 105)
ax.tick_params(axis="x", rotation=45)

# Graph 4: logical vs RSS gap (Zig only)
ax = axes[1, 0]
zig_logical = [b["total_logical_bytes"] / 1024 for b in zig_books]
zig_rss     = [b.get("rss_kb", 0) for b in zig_books]
ax.plot(symbols, zig_logical, marker="o", label="Logical KB")
ax.plot(symbols, zig_rss,     marker="s", label="RSS KB")
ax.set_title("Zig: Logical vs RSS")
ax.legend()
ax.tick_params(axis="x", rotation=45)

# Graph 5: savings ratio
ax = axes[1, 1]
savings = [(j["bytes_per_order"] - z["bytes_per_order"]) / j["bytes_per_order"] * 100
           for z, j in zip(zig_books, java_books)]
ax.bar(symbols, savings, color="green")
ax.set_title("Memory Savings vs Java (%)")
ax.tick_params(axis="x", rotation=45)

# Graph 6: active orders vs capacity (Zig)
ax = axes[1, 2]
active   = [b["active_orders"] for b in zig_books]
capacity = [b["slab_capacity_bytes"] // 64 for b in zig_books]  # slots
ax.bar(x - width/2, active,   width, label="Active",   color="steelblue")
ax.bar(x + width/2, capacity, width, label="Capacity", color="lightblue")
ax.set_title("Zig: Active vs Slab Capacity (slots)")
ax.set_xticks(x); ax.set_xticklabels(symbols, rotation=45)
ax.legend()

plt.tight_layout()
plt.savefig("comparison.png", dpi=150)
print("Saved comparison.png")
plt.show()
```

---

### Step 9: `scripts/run_bench.sh`

```bash
#!/usr/bin/env bash
set -e

echo "Building Zig..."
zig build -Doptimize=ReleaseFast

echo "Running Zig benchmark..."
./zig-out/bin/orderbook-bench > results_zig.json

echo "Building Java..."
javac scripts/OrderBookBench.java -d scripts/

echo "Running Java benchmark..."
java -XX:+UseSerialGC -Xms64m -Xmx512m -cp scripts/ OrderBookBench > results_java.json

echo "Generating graphs..."
python3 scripts/compare.py results_zig.json results_java.json
```

---

## Commits

Never include Claude attribution. No "Co-Authored-By: Claude" lines. All commits must appear fully authored by Markos Santos.

---

## First Commands After `git clone`

```bash
# Wire the Zib dependency (populates hash in build.zig.zon automatically)
zig fetch --save https://github.com/MarkosComK/Zib/archive/main.tar.gz

# Verify the 64-byte constraint before writing any logic
zig test src/types.zig

# After each file is written:
zig build test
```
