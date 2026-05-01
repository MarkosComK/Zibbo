# Step 1: Types — `src/types.zig`

## Concept: `extern struct` and cache line alignment

**`extern struct` vs regular `struct`:**

In a normal Zig `struct`, the compiler is free to reorder fields and insert hidden padding bytes to satisfy alignment requirements. An `extern struct` disables that — fields are laid out exactly as you declare them, in order, with no surprise padding. This is the same guarantee C gives you.

Why does that matter here? We want `OrderEntry` to be exactly 64 bytes — one CPU cache line. When the CPU fetches an order from memory, it pulls a full cache line. If one order = one cache line, you get zero wasted bandwidth: every byte fetched is data you need. Java can't do this — every object has a 16-byte header for the GC, plus boxed fields, so you end up at ~128–160 bytes per order.

**The comptime assertion:**

```zig
comptime {
    if (@sizeOf(OrderEntry) != 64)
        @compileError("OrderEntry must be exactly 64 bytes");
}
```

This runs at compile time, not runtime. If you add a field and accidentally change the size, the build fails immediately. It's a regression guard built into the type system. The test at line 42 is redundant on purpose — it's readable documentation that also runs at runtime.

---

## Memory layout diagram

```
Byte:  0         8         16        24        32        40        48        56  57  58        64
       ┌─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───┬───┬─────────┐
       │order_id │  price  │  size   │trade_id │trade_prc│trade_sz │  time   │ S │ A │  pad    │
       │  u64    │  i64    │  i64    │  u64    │  i64    │  i64    │  i64    │u8 │u8 │ [6]u8  │
       └─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴───┴───┴─────────┘
       ◄───────────────────────── 56 bytes ─────────────────────────────────►◄─2─►◄────6────►
                                                                              = 64 bytes total
S = Side (Buy/Sell), A = Action (New/Modify/Execute/...)
```

---

## How each piece works

**Enums — `enum(u8)`**

```zig
pub const Side = enum(u8) { Buy, Sell };
```

The `(u8)` is the *tag type* — it tells Zig to represent this enum as a single byte in memory. Without it, Zig picks the smallest type that fits, but `extern struct` requires you to be explicit because the C ABI must know exactly how many bytes each field occupies. `Buy = 0`, `Sell = 1` automatically.

**Why `i64` for price instead of `f64`?**

Floating point has precision loss. `0.1 + 0.2 ≠ 0.3` in IEEE 754. Financial systems use fixed-point: store price as an integer multiplied by 10⁸. So `$1.23` is stored as `123_000_000`. You do all arithmetic in integers, no rounding drift.

**Explicit padding — `_pad: [6]u8`**

Without the pad the struct would be 58 bytes. The CPU would fetch 64 bytes anyway (one cache line), but those trailing 6 bytes would belong to the *next* order in the slab — that's the false sharing problem. The pad makes the boundary explicit and intentional. The `_` prefix signals to readers that these bytes carry no meaning.

**`PriceLevel` — plain struct, not `extern`**

```zig
pub const PriceLevel = struct { ... }
```

Only used inside the Zig process (in `PriceLevelIndex` arrays), never passed to C. So we don't need the ABI guarantee — Zig can lay it out however it wants.

---

## Does this file use Zib?

No. `types.zig` is pure primitive types — no utilities needed. Zib's `math`/`str`/`cast` modules will come into play in later steps.

Note: `zig fetch --save` for Zib also fails because Zib has no `build.zig.zon` of its own. Zib integration will be handled manually when a step actually needs it.

---

## Q&A

### Q: Why does every order need exactly 64 bytes? Is it enough?

**Why exactly 64 bytes — the cache line story:**

Your CPU doesn't fetch individual bytes from RAM. It fetches in fixed chunks called **cache lines** — and on virtually every modern x86/ARM processor, that chunk is **64 bytes**.

So when your code touches `order.price`, the CPU pulls the entire 64-byte line into L1 cache, whether you asked for it or not. That's just how the hardware works.

Three scenarios:

- **Order = 64 bytes:** Touch one order → 1 cache line fetched → all fields already in cache. Done.
- **Order = 128 bytes:** Touch one order → 2 cache lines fetched. If you only needed `price`, you wasted 50% of the bandwidth. At 10,000 orders under hot loop conditions, this compounds.
- **Order = 48 bytes:** Worse — two orders share a cache line. Thread A modifies order 0, Thread B reads order 1 → **false sharing**. The CPU sees one dirty cache line and invalidates it for both, even though they touched different data.

64 bytes is not arbitrary — it's the hardware's natural unit. Aligning your struct to it means one order = one fetch, with no waste and no sharing.

**Is 64 bytes enough for the data?**

Yes. Final field breakdown (as actually implemented):

| Field | Type | Bytes | Purpose |
|---|---|---|---|
| `order_id` | u64 | 8 | identify the order |
| `price` | i64 | 8 | fixed-point price (×10⁸) |
| `size` | i64 | 8 | remaining quantity |
| `trade_id` | u64 | 8 | last trade that touched it |
| `trade_price` | i64 | 8 | price of that trade |
| `trade_size` | i64 | 8 | size of that trade |
| `time` | i64 | 8 | timestamp |
| `side` | u8 | 1 | buy or sell |
| `action` | u8 | 1 | new/modify/cancel/etc |
| `_pad` | [6]u8 | 6 | explicit filler to hit 64 |

**Correction from original spec:** `executed_size` was listed as a field in CLAUDE.md but that gives 8 × 8-byte fields = 64 bytes before even adding the enums and pad — total would be 72. Removed it. Executed amount is computable as `original_size - size` and doesn't need to live in the hot struct.

If you needed more fields — participant ID, venue code, flags — you'd either go to 128 bytes (two cache lines, accepted cost) or compress fields via bitpacking.

**The 6 bytes of padding are yours to grow into.** Add a field later, shrink the pad. The comptime assertion catches you the moment you'd overflow 64.
