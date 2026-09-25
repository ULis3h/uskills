---
name: cpp-performance
description: Write, optimize, and benchmark high-performance C++ with the ClickHouse mindset: measure everything, design data layout for the cache, process data in batches instead of per element, specialize the hot path, avoid hidden allocation and dispatch, and prove speedups with benchmarks and hardware counters. Use this skill whenever C++ code is on a hot path or the user mentions performance, latency, throughput, speed, "too slow", profiling, benchmarks, SIMD, vectorization, cache, memory usage, allocation, hash tables, sorting, parsing, serialization, or data-intensive systems (databases, analytics, storage engines, networking), even if they only ask to "make it faster" or "write an efficient X". Also use it when reviewing code for performance regressions.
---

# C++ performance: the ClickHouse way

ClickHouse's performance culture rests on a few habits: **treat every line as
potentially hot until proven otherwise, design around the memory hierarchy,
turn per-element work into per-batch work, specialize the common case, and
never claim a speedup you did not measure.** Complexity is acceptable in
exchange for measured performance; slowness is not acceptable in exchange
for a generic abstraction.

Use this alongside `cpp-style`: fast code can still have clear names,
explicit ownership, and a small API. Performance work changes what happens
*inside* the function, not how it is called.

Reference files (read the one that matches the problem):

- `references/measurement.md`: benchmarks, `perf`, hardware counters, and the
  pitfalls that produce fake speedups. **Read this before optimizing
  anything.**
- `references/data-layout.md`: structure-of-arrays, `PODArray`-style
  containers, alignment, padding, cache lines, huge pages.
- `references/hash-tables.md`: open addressing, saved hashes, two-level
  tables, string-key specialization, prefetching.
- `references/memory.md`: arenas, allocators, jemalloc, avoiding allocation
  in loops, memory accounting.
- `references/vectorization.md`: making loops auto-vectorize, explicit SIMD,
  runtime CPU dispatch, branchless code.
- `references/algorithms.md`: sorting, searching, parsing, and compression
  tricks that ClickHouse relies on.

## 1. The method

1. **Establish the baseline.** A benchmark or a production profile, with
   realistic data sizes and distributions. No baseline, no optimization.
2. **Find where time goes.** `perf record` + flame graph, or the benchmark's
   per-phase breakdown. Optimize the top of the profile, not the code you
   happen to be reading.
3. **Form a hypothesis about the hardware.** Is it memory-bound (cache
   misses, bandwidth), compute-bound (IPC low, port pressure), branch-bound
   (mispredictions), or waiting (locks, syscalls, I/O)? `perf stat` counters
   answer this; guessing does not.
4. **Change one thing.** Measure again. Keep the change only if the numbers
   moved outside noise. Try several alternatives; ClickHouse routinely
   implements two or three variants of a hot routine and keeps the winner.
5. **Protect the win.** Add the benchmark to the repository; ClickHouse runs
   performance tests on every pull request and flags regressions.

## 2. Principles that decide the design

**Batch, don't iterate.** Process arrays of values, not single values. A
virtual call, a branch on the type, a lock, a bounds check, or a function
pointer per *element* is the single most common performance bug. Hoist it to
per-*block* (ClickHouse processes columns in blocks of ~65k rows), and let
the inner loop be a tight loop over contiguous memory with no calls inside.

```cpp
// Slow: dynamic dispatch per element.
for (size_t i = 0; i < n; ++i) result[i] = column->GetValueAsDouble(i) * k;

// Fast: dispatch once, then a vectorizable loop over raw data.
if (const auto* col = dynamic_cast<const ColumnFloat64*>(column)) {
  const double* __restrict src = col->data();
  double* __restrict dst = result.data();
  for (size_t i = 0; i < n; ++i) dst[i] = src[i] * k;
}
```

**Layout for the cache.** Memory access pattern dominates. Prefer
structure-of-arrays over array-of-structures for anything scanned;
keep hot fields together and cold fields elsewhere; avoid pointer chasing
(`std::list`, `std::map`, `std::unordered_map`, trees of `shared_ptr`).
Sequential access to a contiguous array is 10-100x faster than random
access, and the prefetcher only helps with predictable strides.

**Specialize the common case.** Generic code pays for generality on every
call. Use templates to generate a dedicated code path per type or per
configuration (ClickHouse instantiates aggregate functions, hash tables and
comparators per key type), keep a generic fallback for the long tail, and
choose the path once per batch. `if constexpr`, tag dispatch, and
`switch` over an enum into template instantiations are the tools.

**Allocation is expensive; allocation in a loop is a bug.** `reserve()`,
reuse buffers across calls, use arenas for many small objects with the same
lifetime, and prefer `std::string_view`/`std::span` to copying. Watch for
hidden allocations: `std::function`, `std::string` from `const char*`,
`std::vector` returned by value in a loop, `std::shared_ptr` control blocks,
`std::regex`, iostreams.

**Branches should be predictable or absent.** In data-dependent inner
loops, replace unpredictable `if` with arithmetic or conditional moves
(`x = cond ? a : b` on plain scalars compiles to `cmov`), sort or partition
data so branches become predictable, or use lookup tables. Keep the
predictable branches (loop bounds, error checks with `[[unlikely]]`).

**Fewer, bigger operations.** One `memcpy` of 64 KB beats 8192 copies of
8 bytes. One syscall with a large buffer beats many small ones. One hash of a
whole key beats hashing fields separately and combining.

**Integer width, signedness, and overflow matter.** Use `size_t` for sizes
and indices, fixed-width types for storage, `uint64_t` for hashing. Avoid
mixing signed and unsigned in a loop condition (it blocks vectorization and
adds sign-extension). Do not use `double` for counting.

**The compiler is your partner, not your adversary.** Write loops it can
vectorize (see `references/vectorization.md`), mark non-aliasing pointers
`__restrict`, keep hot functions small enough to inline, use `[[likely]]`
and `[[unlikely]]` where profile shows skew, build with `-O3`, LTO, and
consider PGO. Then *look at the assembly* for the hot loop.

## 3. What to avoid on a hot path

| Avoid | Because | Use instead |
|---|---|---|
| `std::map`, `std::set`, `std::list` | Pointer chasing, node allocation | `std::vector` + sort, `absl::flat_hash_map`, custom open-addressing table |
| `std::unordered_map` | Chained buckets, cache-hostile | `absl::flat_hash_map` or a ClickHouse-style linear-probing table |
| `std::shared_ptr` copies | Atomic refcount traffic, false sharing | pass `const T&` / `T*`, `unique_ptr` |
| `std::function` per call | Indirect call, possible heap alloc | template parameter, `absl::FunctionRef` |
| virtual call per element | No inlining, branch target misses | dispatch per batch |
| `std::string` concatenation, `std::stringstream`, `iostream` | Allocations, locale, virtual calls | `absl::StrCat`, `fmt`, a preallocated buffer |
| exceptions for expected outcomes | Unwinding is ~1000x a branch | return codes / `Status`, `expected` |
| `std::vector<bool>` | Bit manipulation per access | `std::vector<uint8_t>` |
| `std::regex` | Extremely slow, allocates | `re2`, hand-written scanner |
| `dynamic_cast` per element | RTTI lookup | check once per batch, `typeid` compare, or a type enum |
| `%` and `/` by non-constants | 20-90 cycles | multiply by precomputed reciprocal, power-of-two masks |
| locks in the inner loop | Cache-line bouncing | thread-local accumulation, merge at the end |
| `-fno-exceptions` debates | irrelevant | measure |

## 4. Measurement discipline (summary; details in `references/measurement.md`)

- Benchmark with realistic sizes: L1-resident data behaves nothing like
  DRAM-resident data. ClickHouse benchmarks on billions of rows because
  that's what runs in production.
- Use Google Benchmark with `benchmark::DoNotOptimize` and
  `benchmark::ClobberMemory`; report ns/element or GB/s, not just ns/op.
- Run `perf stat -e cycles,instructions,cache-misses,branch-misses,
  L1-dcache-load-misses,LLC-load-misses` and read IPC. IPC < 1 usually means
  memory-bound; high branch-miss rate means unpredictable branches.
- Repeat runs, report min or median with noise, pin CPU frequency where
  possible, and disable turbo/SMT for A/B comparisons if you can.
- A microbenchmark speedup that does not show up end-to-end is not a
  speedup. Confirm on the real workload.

## 5. Checklist before calling something "optimized"

- [ ] Baseline number and post-change number, same machine, same data.
- [ ] Profile shows the changed code was actually hot.
- [ ] No allocation inside the inner loop (check with a heap profiler or
      by counting `malloc` calls).
- [ ] Inner loop has no calls, no virtual dispatch, no locks, no branches on
      per-element type.
- [ ] Data accessed sequentially or with prefetch; hot data fits the cache
      level you think it does.
- [ ] Compiler vectorized the loop (`-Rpass=loop-vectorize` /
      `-fopt-info-vec`) or you know why it can't.
- [ ] Benchmark checked in; result documented in the commit message with
      numbers.
- [ ] Correctness tests still pass, including edge cases (empty input, size
      not a multiple of the SIMD width, all-equal keys, adversarial hashes).
- [ ] The fast path has a fallback and the fallback is tested.

## 6. When *not* to optimize

Code that runs once at startup, code whose cost is dominated by I/O it
cannot avoid, and code not on the profile. There, `cpp-style` wins: clarity
first. But "not hot" is a measured claim too; if the function is called per
row, per request, or per packet, assume it is hot.
