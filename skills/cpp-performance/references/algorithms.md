# Algorithmic tricks from a column store

A better algorithm beats a better implementation, and the best algorithm
depends on the data. ClickHouse keeps several implementations of the same
operation and picks by data characteristics at runtime. This file lists the
patterns most likely to transfer to other C++ systems.

Contents:

1. [Sorting](#sorting)
2. [Searching and lookup](#searching-and-lookup)
3. [Parsing and formatting numbers](#parsing-and-formatting-numbers)
4. [Approximate algorithms](#approximate-algorithms)
5. [Compression and I/O](#compression-and-io)
6. [Late materialization and lazy work](#late-materialization-and-lazy-work)
7. [Choosing by data distribution](#choosing-by-data-distribution)

## Sorting

- **`std::sort` is a floor, not a ceiling.** `pdqsort` (pattern-defeating
  quicksort, in ClickHouse and in libc++'s newer `std::sort`) is faster on
  partially sorted or low-cardinality data; `miniselect`/`nth_element` when
  you need the top-K.
- **Radix sort for integers and floats** (ClickHouse `RadixSort`): O(n)
  passes over 8- or 16-bit digits, wins for n > ~10k on fixed-width keys.
  Map floats to sortable integers with the sign-flip trick; sort by a
  packed key.
- **Sort indices, not objects.** Build a `std::vector<uint32_t> perm`,
  sort it by `key[perm[i]]`, then apply the permutation to each column.
  Moving 4-byte indices beats moving 100-byte rows.
- **Top-K with a heap or partial sort**: `std::partial_sort` for small K;
  for `ORDER BY x LIMIT 10` on a billion rows, keep a running threshold
  and filter batches by it before sorting (ClickHouse does this).
- **Sort by cheap key first** and only compare expensive keys on ties.
- Sorting before a hash aggregation or join can turn random access into
  sequential access; sometimes sort + merge beats hashing outright for
  large inputs.

## Searching and lookup

- **Binary search over sorted arrays** beats hash tables for read-only
  data when the array is small enough to stay cached; branchless binary
  search (compute `base += (arr[base + half] < key) * half`) avoids
  mispredictions.
- **Eytzinger layout** (BFS order) makes binary search cache-friendly and
  prefetchable for large arrays.
- **Sparse index / skip index**: store one key per block of 8192 rows
  (ClickHouse primary index), binary search the index, then scan only the
  candidate blocks. Any large sorted dataset benefits from a coarse index
  that fits in cache.
- **Bloom filters / min-max per block** to skip work: cheap to check,
  prune entire chunks before touching them.
- **Interning**: replace repeated string comparisons with integer
  comparisons by mapping strings to ids once.

## Parsing and formatting numbers

- Integer parsing: `std::from_chars` or a hand loop; avoid `strtol`
  (locale, errno) and `std::stoi` (exceptions).
- Float parsing: `fast_float` (ClickHouse uses it) is 5-10x faster than
  `strtod`; `std::from_chars` for doubles is decent in modern libstdc++.
- Formatting: `std::to_chars`, `fmt::format_to` into a buffer, or
  Ryu/Dragonbox for shortest-roundtrip doubles. Never `snprintf("%f")` on
  a hot path.
- Dates: precompute a lookup table indexed by day number (ClickHouse
  `DateLUT`: year/month/day/weekday for every day since 1970, in L2 cache)
  instead of calling `gmtime`.
- Fixed-width decimals as `int64_t`/`int128_t` with a scale, never
  `double` for money.

## Approximate algorithms

When exactness isn't required, approximation changes the complexity class:

- `uniq` / distinct count: HyperLogLog (ClickHouse `uniqHLL12`) or a
  combined "exact up to N, then HLL" (`uniqCombined`); 1.5 KB of state vs a
  hash set of every key.
- Quantiles: t-digest, DDSketch, or reservoir sampling (`quantileTDigest`,
  `quantileTiming`), O(1) memory.
- Top-K frequent items: Space-Saving / heavy hitters (`topK`).
- Set membership: Bloom filter or xor filter.
- Sampling for query planning: estimate cardinalities from a 1% sample
  before choosing an algorithm.

Document the error bound in the API name or doc comment.

## Compression and I/O

- Compressing data on disk and in memory is often a speedup, not a
  slowdown: LZ4 decompresses at 2-5 GB/s per core, faster than DRAM
  bandwidth under contention and far faster than disk. ZSTD trades ratio for
  CPU. ClickHouse compresses every column with LZ4 by default.
- Specialized codecs before general compression: delta, double-delta,
  Gorilla (XOR floats), T64 (transpose bits), then LZ4/ZSTD.
- Read in large blocks (≥ 1 MB) with `posix_fadvise`/`readahead`, or
  `io_uring`/AIO to overlap I/O with compute; avoid many small `read`
  calls.
- Skip work before reading: per-block min/max, sparse index, partition
  pruning, projections.
- Write once, append-only, merge in the background (LSM / MergeTree) beats
  in-place updates for write throughput and sequential reads.

## Late materialization and lazy work

- Read only the columns the query needs, in the order that filters the
  most rows first (`PREWHERE` in ClickHouse: evaluate the cheap selective
  predicate on one column, then read the other columns only for surviving
  rows).
- Compute expensive expressions after filtering and after `LIMIT`, not
  before.
- Represent a filtered subset as a bitmask or an index list and defer
  copying until needed; many operations can consume the mask directly.
- Keep constants as constants (a `ColumnConst` of one value) rather than
  broadcasting to a full column; specialize the kernel for `column op
  constant`.
- Lazy deserialization: parse a header now, the body when someone asks.

## Choosing by data distribution

Implement the alternatives, then pick at runtime by a cheap statistic:

| Statistic | Decision |
|---|---|
| cardinality estimate of a key | direct-index table vs hash table vs sort-based aggregation; two-level vs single-level |
| selectivity of a filter (fraction of rows passing) | branchless compaction (medium), skip whole blocks (very low), no filter at all (very high) |
| sortedness / runs | pdqsort adapts automatically; merge sort for nearly sorted input |
| string length distribution | fixed-width key path vs generic |
| null fraction | separate null-mask path vs generic nullable handling |
| input size | small: `std::vector` linear scan; medium: sort; large: hash / radix |
| available memory | in-memory vs external (spill) algorithm |

The cost of computing the statistic must be small relative to the work; a
sample of the first block is usually enough. Log which path was chosen so
regressions can be diagnosed.
