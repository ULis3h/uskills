# Measuring C++ performance honestly

"We don't know until we measure" is the whole ClickHouse method. This file
covers how to build a benchmark that tells the truth, how to read hardware
counters, and the classic ways a measurement lies.

Contents:

1. [Microbenchmarks with Google Benchmark](#microbenchmarks)
2. [Profiling with perf](#profiling-with-perf)
3. [Hardware counters and what they mean](#hardware-counters)
4. [Ways a benchmark lies](#ways-a-benchmark-lies)
5. [Reading the assembly](#reading-the-assembly)
6. [Reporting results](#reporting-results)

## Microbenchmarks

```cpp
#include <benchmark/benchmark.h>

static void BM_SumU32(benchmark::State& state) {
  const size_t n = state.range(0);
  std::vector<uint32_t> data(n);
  std::iota(data.begin(), data.end(), 0);   // realistic-ish data
  for (auto _ : state) {
    uint64_t sum = 0;
    for (uint32_t x : data) sum += x;
    benchmark::DoNotOptimize(sum);          // result must be "used"
  }
  state.SetItemsProcessed(state.iterations() * n);
  state.SetBytesProcessed(state.iterations() * n * sizeof(uint32_t));
}
// Sweep across cache levels: L1, L2, L3, DRAM.
BENCHMARK(BM_SumU32)->RangeMultiplier(8)->Range(1 << 10, 1 << 26);
```

Rules:

- **Sweep sizes across cache levels.** A loop that is 10x faster on 4 KB may
  be identical on 400 MB because both are bandwidth-bound. Use
  `->Range` and look at the shape, not one point.
- **Use realistic data.** Sorted vs. random, low vs. high cardinality, short
  vs. long strings, ASCII vs. UTF-8: hash tables, branch predictors, and
  string algorithms all behave differently. Generate several distributions
  and name them in the benchmark.
- **`DoNotOptimize` every result, `ClobberMemory()` after writes** the
  optimizer might otherwise elide. Check the assembly if a benchmark seems
  impossibly fast: the loop was probably deleted.
- **Report throughput** (`items/s`, `bytes/s`, ns/element) so numbers are
  comparable across sizes.
- **Measure the thing you will ship.** Same compiler flags (`-O3`, LTO,
  `-march` policy), same allocator (jemalloc vs glibc changes everything),
  same build type.
- **Setup outside the timed loop**, or use `state.PauseTiming()` sparingly
  (it has overhead of its own; prefer amortizing over a batch).
- **Compare in one process where possible** (`BENCHMARK(A); BENCHMARK(B);`)
  and use `--benchmark_repetitions=10 --benchmark_report_aggregates_only`
  to get mean/median/stddev. Use `compare.py` from the benchmark tools to
  diff two runs with a statistical test.

## Profiling with perf

```bash
# Where does the time go? Sampled call stacks with frame pointers.
perf record -g --call-graph fp ./program args      # build with -fno-omit-frame-pointer
perf report --no-children --sort=dso,symbol
# Flame graph
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# Which instructions are hot inside a function?
perf annotate --stdio -s HotFunction

# Counters for the whole run
perf stat -e cycles,instructions,branches,branch-misses,\
cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses,dTLB-load-misses ./program args
```

- Profile a **release build with debug info** (`-O2/-O3 -g
  -fno-omit-frame-pointer`). Inlining changes the profile; a debug build's
  profile is fiction.
- Use `--call-graph dwarf` if frame pointers are unavailable, at the cost of
  larger traces.
- For production, ClickHouse has a built-in sampling profiler
  (`system.trace_log`) precisely because microbenchmarks miss interaction
  effects. If the project has something similar, use it.
- `perf c2c` finds false sharing; `perf mem` finds which loads miss.
- Off-CPU time (locks, I/O, page faults) does not show in `perf record` by
  default. Use `perf sched`, `offcputime` (bcc), or `strace -c` when the CPU
  profile does not explain wall time.

## Hardware counters

| Symptom | Likely cause | What to try |
|---|---|---|
| IPC < 1, high `LLC-load-misses` | Memory-bound, random access | Layout change (SoA), prefetch, smaller data types, sort for locality |
| IPC < 1, low misses, high `dTLB-load-misses` | Page walks | Huge pages, fewer scattered allocations, arenas |
| `branch-misses` > ~2% of branches | Unpredictable branches | Branchless code, sorting, tables |
| IPC 3-4, no misses | Compute-bound | SIMD, fewer instructions, cheaper ops (no div), better algorithm |
| Low cycles but high wall time | Waiting | Off-CPU profile: locks, syscalls, page faults |
| Instructions grew, cycles fell | Fine; you traded cheap instructions for expensive stalls | Keep |

Rules of thumb (approximate, 2020s x86 server): L1 hit ~1 ns, L2 ~4 ns, L3
~10-40 ns, DRAM ~80-120 ns; branch mispredict ~15-20 cycles; integer div
~20-40 cycles; `malloc` 20-100 ns; mutex uncontended ~20 ns, contended
~1 µs+; a virtual call that mispredicts ~20 cycles; a syscall ~200 ns-1 µs;
`memcpy` ~10-30 GB/s per core; one core streaming from DRAM ~10-20 GB/s.
Use these to sanity-check a result: if you claim 100 GB/s from DRAM on one
core, the benchmark is lying.

## Ways a benchmark lies

1. **Dead code elimination.** Result unused, loop removed. Fix:
   `DoNotOptimize`.
2. **Constant folding.** Inputs are compile-time constants, the compiler
   precomputes. Fix: read inputs from a vector filled at runtime, or pass
   through `DoNotOptimize`.
3. **Cache warmth.** First iteration pulls data into cache; later
   iterations are fast; production is cold. Fix: size the data larger than
   the cache, or explicitly flush between iterations when measuring cold
   behavior.
4. **Frequency scaling and turbo.** Single-thread benchmarks run at turbo
   frequency; the real multi-threaded workload doesn't. Fix: pin the
   governor to `performance`, disable turbo for A/B, report cycles not ns.
5. **Noisy neighbors.** Other processes, SMT siblings, background
   indexers. Fix: `taskset` to an isolated core, repeat, take the minimum
   or median and report the spread.
6. **Allocator state.** The first `malloc` of a size class is slow; freed
   memory is reused. Fix: warm-up iterations; measure with the production
   allocator.
7. **Unrealistic branch predictability.** Random data in the benchmark vs.
   mostly-sorted data in production (or vice versa). Fix: multiple
   distributions.
8. **Denormals, NaN, -ffast-math.** Floating point that hits subnormals is
   100x slower; `-ffast-math` in the benchmark but not the build lies.
9. **Measuring the wrong thing.** The change made the microbenchmark 3x
   faster, and the end-to-end query 0% faster, because the function was 2%
   of the profile. Fix: profile first.
10. **Alignment luck.** Code layout changes shift loop alignment and change
    results by ±10% for unrelated reasons. Fix: `-falign-functions=64`,
    multiple runs, be suspicious of small deltas.

## Reading the assembly

`objdump -d --no-show-raw-insn -C binary | less` or Compiler Explorer with
the same flags. For the hot loop, check:

- Is it vectorized? Look for `ymm`/`zmm` (x86) or `v0.4s`/`z0` (ARM)
  registers and `vpaddd`, `vmovdqu`, etc.
- Is there a `call` inside the loop? Something didn't inline.
- Are there `div`/`idiv`? Replace with multiplication or shifts.
- Are there bounds checks or null checks per iteration that could be hoisted?
- `cmov` vs. `jcc`: branchless where you intended?
- Use `llvm-mca` to estimate throughput of the loop body and spot port
  pressure.
- Use `-Rpass=loop-vectorize -Rpass-missed=loop-vectorize
  -Rpass-analysis=loop-vectorize` (clang) or `-fopt-info-vec-all` (gcc) to
  learn why a loop did not vectorize.

## Reporting results

In the commit message or PR:

```
Speed up ColumnString::compareAt by specializing on equal lengths.

Benchmark (bench/column_string_compare, 10 reps, median):
  strings len 8,  random:   112 ns/op -> 41 ns/op  (2.7x)
  strings len 64, random:   130 ns/op -> 58 ns/op  (2.2x)
  strings len 8,  all equal: 40 ns/op -> 39 ns/op  (noise)
End-to-end: ORDER BY on 100M rows of hits.URL: 4.1 s -> 3.2 s.
perf stat: branch-misses 6.1% -> 0.9%.
```

Numbers, distributions, both micro and end-to-end, the counter that
explains why. That is the standard.
