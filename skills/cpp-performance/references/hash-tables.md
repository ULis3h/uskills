# Hash tables the ClickHouse way

`GROUP BY`, `JOIN`, `DISTINCT`, `IN`: most of ClickHouse's CPU time is hash
table work, so its tables are hand-built. The same principles apply to any
hot lookup structure.

Contents:

1. [Choosing a table](#choosing-a-table)
2. [Open addressing with linear probing](#open-addressing)
3. [Hash functions](#hash-functions)
4. [Key specialization](#key-specialization)
5. [Saved hashes and prefetching](#saved-hashes-and-prefetching)
6. [Two-level tables and parallel merge](#two-level-tables)
7. [Pitfalls](#pitfalls)

## Choosing a table

| Need | Use |
|---|---|
| General purpose, values movable, no pointer stability | `absl::flat_hash_map` (SwissTable: SIMD group probing, ~7/8 load factor) |
| Pointer stability of values | `absl::node_hash_map` or `flat_hash_map<K, unique_ptr<V>>` |
| Ordered iteration / range queries | `absl::btree_map` |
| ≤ ~32 entries | sorted `std::vector` or linear scan of `std::vector<pair>` |
| Fixed key set known up front | perfect hash / sorted array + binary search / `switch` |
| Integer keys, dense-ish range | direct-indexed array (ClickHouse `FixedHashTable` for `UInt8`/`UInt16` keys: 256 or 65536 slots, no hashing at all) |
| Hot aggregation with billions of keys | custom open-addressing table sized and specialized for the key type |
| Concurrent reads, rare writes | build immutable table, swap pointer (RCU-style) |
| Concurrent writes | per-thread tables + merge (see two-level), not a lock around one table |

`std::unordered_map` is never the answer on a hot path: node allocation per
element, a pointer chase per probe, and a slow hash.

## Open addressing

ClickHouse's `HashTable` is linear probing with a power-of-two capacity:

- **Storage**: one flat array of cells; a cell is the key (and value)
  inline. Empty cells are marked by a sentinel key (zero) with the zero key
  itself stored in a special slot, avoiding a separate tag array.
- **Probe**: `idx = hash & mask; while (!empty(idx) && key(idx) != k) idx =
  (idx + 1) & mask;`. Linear probing is cache-friendly: the next probe is
  in the same or adjacent line.
- **Load factor** ≤ 0.5 before resize (ClickHouse grows at 50%: probe
  sequences stay short, and the cost is memory, which is cheaper than
  cache misses).
- **Growth**: double the capacity, reinsert. During reinsertion, ClickHouse
  exploits that with a power-of-two mask, every element either stays or
  moves to `idx + old_capacity`, and reinserts in place without a second
  array where possible.
- **Deletion** in linear probing needs tombstones or backward-shift
  deletion; ClickHouse mostly avoids deletes (build once, query, drop).

SwissTable (`absl::flat_hash_map`) adds a 1-byte control array probed 16
at a time with SSE2, allowing load factors near 7/8 with few key
comparisons. Prefer it as the default; hand-roll only when specialization
(next sections) gives a measured win.

## Hash functions

- For integers: a cheap mixer is enough and speed matters more than
  quality. ClickHouse uses a CRC32-based hash (`_mm_crc32_u64`, one
  instruction, ~3 cycles latency) for `UInt64` keys, and multiplicative
  hashing for small tables. Identity hash is a trap: sequential keys all
  collide modulo the power-of-two mask on low bits.
- For strings: `CityHash64`, `xxHash3`, `wyhash`, or CRC32 over 8-byte
  chunks. Do not use `std::hash<std::string>` (slow, unspecified
  quality) or SipHash where DoS resistance is not needed.
- Combine fields with a proper combiner (`absl::HashOf(a, b)`,
  `H::combine`), never `h1 ^ h2` (symmetric, collides on swapped values)
  or `h1 * 31 + h2` (weak low bits).
- If the table is exposed to untrusted keys and must resist collision
  attacks, use a keyed hash (SipHash, or `absl::Hash` with its per-process
  seed) and a chaining-resistant table.

## Key specialization

One table type per key shape, chosen once per batch, so the inner loop has
no `switch`:

| Key | ClickHouse method | Why |
|---|---|---|
| single `UInt8`/`UInt16` | `FixedHashTable` (direct index) | no hash, no probe |
| single 32/64-bit | `HashMap<UInt64, ...>` with CRC hash | one load per probe |
| several fixed-size columns whose total ≤ 16/32 bytes | pack into `UInt128`/`UInt256` key ("keys_fixed") | one comparison, no per-column dispatch |
| single string | `StringHashMap`: sub-tables for length ≤8, ≤16, ≤24, and generic | short strings compared as integers, no memcmp |
| nullable keys | bitmask packed into the fixed key | avoids branches on null per key |
| anything else | serialize columns into an arena, key = `StringRef` | generic fallback |

The lesson generalizes: when a lookup is hot, make the key a fixed-size
integer if at all possible (intern strings to ids, pack tuples, hash
long keys to 128 bits and accept the collision probability if the domain
allows).

## Saved hashes and prefetching

- **Save the hash in the cell** when keys are expensive to compare or hash
  (strings): a 64-bit hash compare rejects most mismatches without touching
  the key bytes, and resizing does not rehash.
- **Compute all hashes first, then probe** in a second pass over the batch.
  This allows `__builtin_prefetch(&cells[hashes[i + 16] & mask])` a few
  iterations ahead, hiding DRAM latency: ClickHouse got 1.5-2x on large
  aggregations from this alone.
- Batch inserts: `emplace` many keys in one call so the table does one
  resize check per batch instead of per key.

## Two-level tables

For parallel aggregation, ClickHouse gives each thread its own table.
Merging N tables is then the bottleneck. Fix: when a table grows past a
threshold, convert it into 256 buckets keyed by the hash's high byte
("two-level"). Merging becomes 256 independent jobs (bucket i from every
thread merges into one), parallel and cache-friendly, and huge tables can
be spilled or merged bucket by bucket with bounded memory.

The general principle: **partition by hash to make work embarrassingly
parallel**, instead of sharing one structure under a lock.

## Pitfalls

- Iterating a hash table in an inner loop (iteration order is random,
  every step a cache miss). Copy to a vector and sort if you need order or
  locality.
- Holding a reference into `flat_hash_map` across an insert (rehash
  invalidates everything).
- Using `map[key]` for lookups: it inserts a default value on miss.
- Rehashing at 90% load in a linear-probing table: probe length explodes.
  Stay ≤ 0.5-0.7 unless using SwissTable-style tag probing.
- Storing `std::string` keys when `std::string_view` into an arena would
  do: one allocation per key becomes zero.
- Hashing `float`/`double` bitwise without canonicalizing `-0.0` and NaN.
- Forgetting to `reserve` when the size is known: repeated growth
  dominates small-table build time.
