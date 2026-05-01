# Step 1: Types — `src/types.zig`

## Concept: `extern struct` and cache line alignment

Before implementing, here's what this file teaches.

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

This runs at compile time, not runtime. If you add a field and accidentally change the size, the build fails immediately. It's a regression guard built into the type system.

---

## Q&A

### Q: Why does every order need exactly 64 bytes? Is it enough?

**Why exactly 64 bytes — the cache line story:**

Your CPU doesn't fetch individual bytes from RAM. It fetches in fixed chunks called **cache lines** — and on virtually every modern x86/ARM processor, that chunk is **64 bytes**.

So when your code touches `order.price`, the CPU pulls the entire 64-byte line into L1 cache, whether you asked for it or not. That's just how the hardware works.

Two scenarios:

- **Order = 64 bytes:** Touch one order → 1 cache line fetched → all fields already in cache. Done.
- **Order = 128 bytes:** Touch one order → 2 cache lines fetched. If you only needed `price`, you wasted 50% of the bandwidth. At 10,000 orders under hot loop conditions, this compounds.
- **Order = 48 bytes:** Worse — two orders share a cache line. Thread A modifies order 0, Thread B reads order 1 → **false sharing**. The CPU sees one dirty cache line and invalidates it for both, even though they touched different data.

64 bytes is not arbitrary — it's the hardware's natural unit. Aligning your struct to it means one order = one fetch, with no waste and no sharing.

**Is 64 bytes enough for the data?**

Yes, for this orderbook's needs. Field breakdown:

| Field | Type | Bytes | Purpose |
|---|---|---|---|
| `order_id` | u64 | 8 | identify the order |
| `price` | i64 | 8 | fixed-point price |
| `size` | i64 | 8 | remaining quantity |
| `executed_size` | i64 | 8 | how much filled |
| `trade_id` | u64 | 8 | last trade that touched it |
| `trade_price` | i64 | 8 | price of that trade |
| `trade_size` | i64 | 8 | size of that trade |
| `time` | i64 | 8 | timestamp |
| `side` | u8 | 1 | buy or sell |
| `action` | u8 | 1 | new/modify/cancel/etc |
| `_pad` | [6]u8 | 6 | explicit filler to hit 64 |

That's everything a matching engine needs to process an order event. If you needed more fields — a participant ID, venue code, flags — you'd either go to 128 bytes (two cache lines, accepted cost) or compress fields (bitpacking `side` + `action`, using fixed-width timestamps, etc.).

**The padding tells you there's room to grow.** Those 6 bytes are yours to use. Add a field later and the pad shrinks. The comptime assertion catches you the moment you'd overflow 64.
