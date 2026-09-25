# Data layout for the memory hierarchy

The single largest lever in most C++ performance work is *where the bytes
are*, not what instructions run. ClickHouse is fast primarily because it is
columnar: every operation runs over a contiguous array of one type.

Contents:

1. [Structure of arrays](#structure-of-arrays)
2. [Contiguous, growable, uninitialized: PODArray](#podarray)
3. [Cache lines, alignment, padding](#cache-lines-alignment-padding)
4. [Narrow types and compact encodings](#narrow-types)
5. [Strings and variable-length data](#strings-and-variable-length-data)
6. [Huge pages and TLB](#huge-pages-and-tlb)
7. [Layout checklist](#layout-checklist)

## Structure of arrays

```cpp
// Array of structures: scanning `price` touches every field.
struct Order { int64_t id; double price; uint32_t qty; std::string note; };
std::vector<Order> orders;
double total = 0; for (const auto& o : orders) total += o.price;  // ~80 B per row read

// Structure of arrays: scanning `price` touches only prices, vectorizes.
struct Orders {
  std::vector<int64_t> id;
  std::vector<double> price;
  std::vector<uint32_t> qty;
  std::vector<std::string> note;
};
double total = 0; for (double p : orders.price) total += p;       // 8 B per row read
```

Use SoA when:

- Operations touch a few fields across many elements (analytics, filters,
  aggregations, physics updates).
- You want auto-vectorization; AoS with mixed types almost never vectorizes.
- Elements are appended in bulk and rarely moved individually.

Use AoS when:

- Operations touch most fields of one element at a time (a request
  handler working on one `Request`).
- Elements are individually owned, moved, or have identity.

Hybrid (AoSoA) blocks of 8-64 elements per field are useful for SIMD when
you also need per-element locality. Hot/cold splitting is SoA-lite: move
rarely-used fields (`note`) out of the struct into a side table so the
common scan stays dense.

## PODArray

`std::vector<T>` does two things a hot path does not want: value-initializes
every element on `resize()` (zeroing memory you will overwrite), and offers no
slack for SIMD overreads. ClickHouse's `PODArray` fixes both; you can get most
of the benefit with a small wrapper:

- `resize_uninitialized(n)`: grow without zeroing; the caller promises to
  write before reading. Use `std::unique_ptr<T[]>(new T[n])` for trivial
  `T` with `T` uninitialized, or a custom allocator whose `construct` is a
  no-op (the "default-init allocator" idiom), or `std::vector` +
  `reserve` + explicit writes.
- **Padding at the end** (ClickHouse uses 16 bytes, or 64 for some
  columns): lets a SIMD loop read a full vector at the tail without a scalar
  epilogue, and lets `memcpy`-based parsers read past the end safely.
  Allocate `n + pad`, expose `size() == n`.
- **Geometric growth** with a large first allocation for known-large
  buffers; reuse the buffer across batches (`clear()` keeps capacity).
- `T` must be trivially copyable: use `memcpy`/`realloc` for growth rather
  than element-wise moves.

## Cache lines, alignment, padding

- A cache line is 64 bytes (128 on Apple silicon and some ARM). Data used
  together should be within a line; data written by different threads must
  be on different lines (`alignas(std::hardware_destructive_interference_size)`,
  or `alignas(64)`).
- Order struct members largest-alignment first to avoid padding; check with
  `static_assert(sizeof(T) == expected)` for hot structs so a stray member
  doesn't double the size silently.
- Prefer indices (`uint32_t`) over pointers in large graphs: half the size,
  relocatable, and the array they index is contiguous.
- Align SIMD buffers to 32/64 bytes (`std::aligned_alloc`, `alignas`) so
  aligned loads can be used and lines aren't split.
- Keep hot loop state in registers: small local variables, not members of a
  `this` that the compiler must reload after every store (aliasing).

## Narrow types

Bytes moved is the cost. If a value fits in `uint8_t`, storing it as
`int64_t` makes the scan 8x slower once memory-bound.

- Use the narrowest fixed-width type the domain allows; ClickHouse offers
  `UInt8..UInt256`, `Date` (16 bit), `DateTime` (32 bit), `LowCardinality`
  (dictionary encoding: store `uint8_t`/`uint16_t` indices plus a
  dictionary).
- Dictionary-encode low-cardinality strings and enums.
- Delta / frame-of-reference encode sorted or slowly varying integers;
  bit-pack when values are small (this is what compression codecs like
  `Delta`, `DoubleDelta`, `Gorilla`, `T64` do).
- Bitmaps (`std::vector<uint8_t>` of 0/1, or `roaring`) for filters; a
  filter as a byte mask feeds SIMD compaction directly.
- Prefer `float` over `double` when precision allows: 2x the SIMD lanes.

## Strings and variable-length data

`std::vector<std::string>` is a pointer per string, an allocation per
string (above the SSO limit), and a cache miss per string. Columnar layout:

```cpp
struct StringColumn {
  std::vector<char> chars;       // all bytes back to back, each string
                                 // followed by '\0' (ClickHouse) so it can be
                                 // passed to C APIs without copying
  std::vector<uint64_t> offsets; // offsets[i] = end of string i
  std::string_view operator[](size_t i) const {
    uint64_t begin = i ? offsets[i - 1] : 0;
    return {chars.data() + begin, offsets[i] - begin - 1};
  }
};
```

Fixed-length strings (`FixedString(N)`) store `N * rows` bytes flat and
compare with `memcmp` of fixed size, which the compiler turns into a couple
of loads. For hash-table keys, ClickHouse specializes on key length:
`≤ 8` bytes loaded as `uint64_t`, `≤ 16` as two, `≤ 24` as three, else
generic.

Arrays and nested types use the same offsets trick recursively: an
`Array(UInt32)` column is one flat `uint32_t` array plus one offsets array,
never a `vector<vector<uint32_t>>`.

## Huge pages and TLB

Random access over gigabytes takes a TLB miss (page walk, ~30+ cycles) on
top of the cache miss. Mitigations, in order of effort:

1. Fewer, larger allocations (arenas) so the working set spans fewer pages.
2. Transparent huge pages: `madvise(ptr, size, MADV_HUGEPAGE)` on large
   buffers; jemalloc can do this per arena. ClickHouse uses 2 MB pages for
   its hash tables and marks.
3. Prefetch (`__builtin_prefetch`) a few iterations ahead when the access
   pattern is known but random (hash lookups with precomputed hashes).
4. Explicit huge pages (`mmap` with `MAP_HUGETLB`) for the biggest tables.

## Layout checklist

- [ ] Hot loops read contiguous memory in one direction.
- [ ] Bytes per element in the hot scan is as small as the domain allows.
- [ ] No per-element heap objects (`std::string`, `unique_ptr`, node
      containers) in scanned data.
- [ ] `sizeof` of hot structs asserted; members ordered to avoid padding.
- [ ] Per-thread written data on separate cache lines.
- [ ] Buffers reused across batches; growth is geometric; no zero-fill of
      memory about to be overwritten.
- [ ] Tail padding present if a SIMD loop or `memcpy`-parser reads past the
      end.
