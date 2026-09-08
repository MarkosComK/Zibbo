# Concept: Memory Pooling — This Project vs dxFeed QD Core

Not tied to a single build step — this came out of a tangent while starting Step 2, after
reading about dxFeed QD's use of memory pooling. Recorded here because it explains *why*
Step 4's slab/free_list design looks the way it does, before we've actually written Step 4.

## Concept: object pooling instead of malloc-per-item

The idea: instead of calling `malloc`/`new` for every incoming unit of work (an order, a
tick, a packet) and freeing it when you're done, you allocate a fixed pool of reusable slots
up front, hand one out on demand, and put it back in the pool when done. No allocator call,
no GC pressure, on the hot path.

This matters most in systems processing millions of small events per second — exactly the
market-data situation this project is modeling. In Java, every `new` is a GC-tracked object;
enough of them per second and the collector starts stealing CPU time from actual work. In
Zig, "just don't allocate on the hot path" is achievable directly, which is the whole reason
this project reaches for `extern struct` + arena + free list in the first place (see
[Step 1](./step-01-types.md) for the cache-line side of that story).

## What dxFeed QD actually does

QD (`com.devexperts.qd`) is the reference implementation this whole project benchmarks
against. Its core object, `RecordBuffer`, is acquired and released instead of
constructed/GC'd:

- `RecordBuffer.getInstance()` / `buffer.release()` — acquire from and return to a pool,
  instead of `new RecordBuffer()`.
- **Two-tier pool**: a thread-local pool (default capacity 3) and a global pool (default
  capacity 1024), tunable via the system properties
  `com.devexperts.qd.ng.RecordBuffer.threadLocalCapacity` and `...poolCapacity`.
- **Array-backed storage, not object-per-record**: a `RecordBuffer` holds ticks as columns
  in `int[]`/`Object[]` arrays, not as one heap object per tick. Pooling the *object* only
  gets you so far — the bigger win is not allocating per record at all.
- **Oversized buffers are exempted from the pool** and left for ordinary GC, so one abnormal
  batch doesn't permanently bloat the pool for everyone else.

An independent case study by a market-data systems engineer (Peter Zemtsov,
["To allocate or to pool?"](https://pzemtsov.github.io/2019/01/17/allocate-or-pool.html))
measured the effect of this kind of pooling directly and found pooling won in every
scenario tested — allocation caused GC to dominate execution time and drop packets under
load, while pooling kept per-packet latency low and stable.

> **Confidence note:** the `getInstance`/`release`/pool-capacity/array-storage details above
> were verified against dxFeed's own docs and QD's `ReleaseNotes.txt` at the time this was
> written. The Zemtsov article's exact numbers were relayed through a summarization tool, not
> read verbatim — treat the *conclusion* (pooling beats allocation under load) as solid, but
> re-check the article directly before quoting exact nanosecond figures from it.

## Where this project already does the same thing

Step 4's planned `OrderBook` design (not yet implemented — this doc exists ahead of the code
for once) *is* this pattern, at slot granularity instead of buffer granularity:

| Concept | QD Core (Java) | orderbook-zig (Zig) |
|---|---|---|
| Pool of reusable units | thread-local + global `RecordBuffer` pool | `free_list: []u16` |
| Acquire from pool | `RecordBuffer.getInstance()` | `OrderBook.allocSlot()` |
| Return to pool | `buffer.release()` | `OrderBook.freeSlot()` |
| Backing storage | `int[]`/`Object[]` columns inside the buffer | `slab: []OrderEntry` (64-byte extern struct, see Step 1) |
| Zero-copy read | `RecordCursor` view over the buffer | direct `slab[idx]` access; `out: []PriceLevel` params |
| Reclaiming waste | oversized buffer skipped, left for GC | `compact()` when `unused > max(active >> 2, 25)` |
| External id → internal slot | symbol/record interning (`DataScheme`, roughly) | `id_map: HashMap(u64 → u16)` |

### Flow, side by side

```
┌─────────────────────────────────────────┐   ┌─────────────────────────────────────────┐
│         dxFeed QD Core (Java)            │   │         orderbook-zig (Zig)              │
├─────────────────────────────────────────┤   ├─────────────────────────────────────────┤
│  network feed                            │   │  feed.zig (synthetic order feed)         │
│       │                                  │   │       │                                   │
│       ▼                                  │   │       ▼                                   │
│  RecordBuffer.getInstance() ◄───┐        │   │  OrderBook.allocSlot() ◄───┐             │
│       │                          │        │   │       │                    │             │
│       │              [ POOL ]    │        │   │       │        [ POOL ]    │             │
│       │        thread-local(3)   │        │   │       │      free_list:    │             │
│       │        + global(1024)    │        │   │       │        []u16       │             │
│       │                          │        │   │       │                    │             │
│       ▼                          │        │   │       ▼                    │             │
│  write ticks into                │        │   │  slab[idx] = entry         │             │
│  int[]/Object[] columns          │        │   │  (extern struct,           │             │
│  (no per-record object)          │        │   │   arena-backed, 64B)       │             │
│       │                          │        │   │       │                    │             │
│       ▼                          │        │   │       ▼                    │             │
│  Distributor / QDTicker /        │        │   │  id_map.put(order_id→idx)  │             │
│  QDStream routes buffer          │        │   │  bid_index/ask_index       │             │
│       │                          │        │   │  .update(price, ±size)    │             │
│       ▼                          │        │   │       │                    │             │
│  consumer reads via              │        │   │       ▼                    │             │
│  RecordCursor (in place,         │        │   │  getBestBid()/             │             │
│  zero-copy)                      │        │   │  getPriceLevels(out)       │             │
│       │                          │        │   │  (writes into caller buf) │             │
│       ▼                          │        │   │       │                    │             │
│  buffer.release() ───────────────┘        │   │       ▼                    │             │
│  (too-big buffer → abandoned to GC)       │   │  deleteOrder()→freeSlot()──┘             │
│                                           │   │  (compact() defrags slab               │
│                                           │   │   when unused > threshold)              │
└─────────────────────────────────────────┘   └─────────────────────────────────────────┘
```

## The real structural difference

QD's unit of reuse is a whole **buffer instance** — check one out, fill it with many
records, ship it downstream, release the whole thing at once. Our slab's unit of reuse is a
single **slot** inside one long-lived array — closer to a custom bump/free-list allocator
than to "object pooling" in the classic sense QD demonstrates.

Both eliminate the same failure mode (a malloc/GC event per tick), but the granularity
differs — QD pools at *batch* granularity, we pool at *record* granularity. That difference
is also exactly why `compact()` needs to exist here and has no QD equivalent: a whole
recycled buffer never fragments internally, but a single big array does as slots free up out
of order. QD trades that away by paying for many small buffer instances instead of one big
array.

## Open follow-ups (not yet decided)

Two ways to make this comparison concrete instead of conceptual, once Step 4 lands:

1. **A generic `Pool(T)` abstraction in Zig**, separate from the slab-specific
   `free_list`, used for something transient (e.g. per-tick event structs passed from
   `feed.zig` into `orderbook.zig`). Would demonstrate pooling as a reusable pattern, not
   just baked into one struct.
2. **A pooled-vs-naive-allocation Java micro-benchmark.** `scripts/OrderBookBench.java`
   currently does a naive `new long[]{...}` per order into a `HashMap` — it does not model
   QD's actual technique at all. Adding a second path that pools `long[]` records via a
   `ThreadLocal` free list (RecordBuffer-style) and comparing it against the naive path would
   let this project reproduce the "pooling beats allocation" result directly in
   `results_java.json`, isolating the pooling variable instead of conflating it with
   Zig-vs-Java.

Neither has been decided on yet — revisit when Step 4 (`orderbook.zig`) or Step 7
(`OrderBookBench.java`) actually comes up.

## References

- [RecordBuffer (QD Core API)](https://docs.dxfeed.com/qd-core/api/com/devexperts/qd/ng/RecordBuffer.html) — `getInstance`/`release`, array-backed storage, thread-safety notes.
- [QD `ReleaseNotes.txt`](https://github.com/Devexperts/QD/blob/master/ReleaseNotes.txt) — pool capacity system properties (`threadLocalCapacity`, `poolCapacity`).
- Peter Zemtsov, [`To allocate or to pool?`](https://pzemtsov.github.io/2019/01/17/allocate-or-pool.html) — independent benchmark of pooling vs allocation in a packet-processing/market-data-adjacent context. Numbers relayed via summarization tool — re-verify directly before citing specific figures elsewhere.
