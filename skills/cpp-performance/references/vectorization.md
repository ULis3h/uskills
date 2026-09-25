# Vectorization, SIMD, and branchless code

Modern cores execute 4-16 lanes per instruction with AVX2/AVX-512/NEON/SVE.
Most of that potential is reached not by hand-written intrinsics but by
writing loops the compiler can vectorize, over data laid out for it.

Contents:

1. [Loops the compiler will vectorize](#loops-the-compiler-will-vectorize)
2. [Checking what happened](#checking-what-happened)
3. [Branchless patterns](#branchless-patterns)
4. [Explicit SIMD](#explicit-simd)
5. [Runtime CPU dispatch](#runtime-cpu-dispatch)
6. [Common hot kernels](#common-hot-kernels)

## Loops the compiler will vectorize

A loop auto-vectorizes when the compiler can prove all of the following:

- **Trip count is computable** before the loop starts: `for (size_t i = 0;
  i < n; ++i)` with `n` not modified inside. `while (*p)` and early `break`
  usually defeat it.
- **No loop-carried dependency** except reductions (`sum += x[i]`) and
  simple inductions. `a[i] = a[i - 1] + x` cannot vectorize.
- **No aliasing** between written and read arrays. Raw pointers of the same
  type are assumed to alias: mark them `__restrict`, or use local copies of
  `data()` pointers, or `std::vector` element types that differ. Member
  pointers (`this->dst_[i] = this->src_[i]`) are especially bad: the store
  might modify `this`, forcing a reload every iteration. Copy members to
  locals before the loop.
- **No function calls** in the body, except inlined ones and known
  vectorizable math (`std::abs`, `std::min`, `sqrt`; `std::sin` only with
  a vector math library).
- **Straight-line body** or `if`s that convert to selects: `x[i] = c[i] ?
  a[i] : b[i]` vectorizes; a branch that does I/O or throws does not.
- **Contiguous, unit-stride access.** Strided or gathered access
  (`a[idx[i]]`) vectorizes only with gather instructions and rarely pays.
- **Integer types consistent.** Mixing `int` and `size_t` or signed/unsigned
  adds sign extensions that block or slow vectorization. Use `size_t`
  indices and same-width element types.
- **Float reductions** need `-ffast-math` or `-fassociative-math` (or
  `#pragma clang loop vectorize(enable)` / `#pragma omp simd reduction`)
  because reassociation changes results. Decide whether that's acceptable;
  ClickHouse accepts it for aggregates like `sum`.
- **Bounds checks** (`.at()`, hardened `operator[]`) inside the loop must
  be hoisted; iterate over a `std::span` sized once.

```cpp
// Vectorizes: restrict pointers, size_t, no calls, no aliasing with members.
void Scale(const float* __restrict src, float* __restrict dst, size_t n, float k) {
  for (size_t i = 0; i < n; ++i) dst[i] = src[i] * k;
}

// Filter to a mask, vectorizes (compare -> select).
void GreaterThan(const int32_t* __restrict a, int32_t threshold,
                 uint8_t* __restrict mask, size_t n) {
  for (size_t i = 0; i < n; ++i) mask[i] = a[i] > threshold;
}
```

## Checking what happened

```bash
clang++ -O3 -Rpass=loop-vectorize -Rpass-missed=loop-vectorize \
        -Rpass-analysis=loop-vectorize -c kernel.cc
g++ -O3 -fopt-info-vec-missed -c kernel.cc
```

Read the reason ("loop not vectorized: unsafe dependent memory operations"
means aliasing; "could not determine number of loop iterations" means the
trip count; "call instruction cannot be vectorized" means an unexpected
call). Then confirm in the disassembly that the hot loop uses vector
registers, and benchmark. A vectorized loop that is memory-bound may show
no speedup; that tells you the bottleneck moved, which is fine.

## Branchless patterns

Branch mispredictions cost ~15-20 cycles each. When the outcome depends
on data with no pattern, remove the branch:

```cpp
// Mispredicts on random data.
if (x[i] > t) count++;
// Branchless (compiles to setcc/add or vectorizes).
count += x[i] > t;

// Min/max: std::min compiles to cmov/vminps; a hand-written if may not.
m = std::min(m, x[i]);

// Compaction (filter): write unconditionally, advance conditionally.
out[pos] = in[i];
pos += mask[i];

// Select between two values with arithmetic on the mask.
result = (a & -static_cast<uint32_t>(cond)) | (b & ~-static_cast<uint32_t>(cond));
```

Keep branches when they *are* predictable: error paths, `[[unlikely]]`
checks, loops over mostly-sorted data. Branchless code executes both sides;
if one side is expensive, a branch that predicts 99% of the time wins.
Measure with `perf stat -e branch-misses`.

Data reordering also removes mispredictions: sorting, partitioning
by a predicate, or processing "all true rows, then all false rows"
(ClickHouse's filter-then-process pipeline does exactly this).

## Explicit SIMD

Reach for intrinsics when the compiler cannot express the operation
(shuffles, byte-wise compaction, string search, hashing), and confirm with
a benchmark that it beats the scalar/auto-vectorized version.

- Prefer a portable wrapper (`google/highway`, `xsimd`, `std::simd` in
  C++26 / `std::experimental::simd`) over raw `_mm256_*` so one source
  targets SSE, AVX2, AVX-512, NEON, SVE.
- Write the scalar version first, keep it as the fallback and the test
  oracle; fuzz both with random inputs and every length 0..3*width to catch
  tail bugs.
- Handle the tail: masked ops (AVX-512, SVE), an overlapping final vector
  (process the last `width` elements even though they overlap, if the
  operation is idempotent), or padded buffers (see `data-layout.md`).
- Alignment: use unaligned loads (`loadu`) unless you control the buffer;
  the penalty for unaligned is negligible on modern cores except across a
  cache-line split.
- Watch AVX-512 frequency throttling on older Intel parts; measure whole
  program throughput, not the kernel alone.
- ClickHouse's typical wins: `memcpy`/`memcmp` variants for short lengths,
  UTF-8 validation, case conversion, `LIKE` substring search (SIMD
  `strstr`), numeric parsing, filter compaction, and hash computation.

## Runtime CPU dispatch

A binary built for the oldest CPU it must run on leaves 2-8x on the table
for newer cores. Compile the hot kernel several times and pick at runtime:

```cpp
// Compile this TU once per target with -mavx2 / -mavx512f and different
// namespaces, or use the target attribute:
__attribute__((target("avx2"))) void SumAvx2(const float*, size_t, float*);
__attribute__((target("avx512f"))) void SumAvx512(const float*, size_t, float*);
void SumDefault(const float*, size_t, float*);

using SumFn = void (*)(const float*, size_t, float*);
SumFn ChooseSum() {
  if (__builtin_cpu_supports("avx512f")) return SumAvx512;
  if (__builtin_cpu_supports("avx2")) return SumAvx2;
  return SumDefault;
}
// Resolve once (static local or function multiversioning `target_clones`).
```

ClickHouse wraps this in `DECLARE_MULTITARGET_CODE`/`MULTITARGET_FUNCTION_*`
macros; Highway has `HWY_DYNAMIC_DISPATCH`. Never build the entire binary
with `-march=native` for distribution; do it only for local benchmarks,
and even then compare against the shipped flags.

## Common hot kernels

| Kernel | Approach |
|---|---|
| sum / min / max over an array | plain loop, `__restrict`, reduction; `-ffast-math` for floats if acceptable |
| filter rows by mask | compaction loop with unconditional write (above), or `vpcompress`/table-based shuffle for AVX2 |
| count set bits | `std::popcount` per word (`-mpopcnt`), not per bit |
| find byte in buffer | `memchr` (already SIMD); for two bytes, `memchr` + verify |
| compare strings of length ≤ 16 | load as `uint64_t` pairs, mask, compare |
| parse many integers | `std::from_chars` per number is fine; for known-length fixed formats, SIMD parsing (see simdjson) |
| hash a stream of 64-bit keys | CRC32 or multiplicative hash in a loop, one output per element, no table access in the same loop |
| copy with a stride / transpose | blocked transpose with 4x4 or 8x8 register tiles |
| lowercase ASCII | `c | (0x20 & mask_is_upper)` per byte, vectorizes |
