# Memory management for throughput

Allocation is the most common hidden cost in C++. A `malloc`/`free` pair is
50-200 ns, touches allocator metadata (cache misses), may take a lock, and
scatters objects across the heap so later access misses too. ClickHouse's
rule: allocate in bulk, own memory in arenas, account for every byte.

Contents:

1. [Finding allocations](#finding-allocations)
2. [Removing allocations from loops](#removing-allocations-from-loops)
3. [Arenas](#arenas)
4. [Allocators](#allocators)
5. [Memory accounting and limits](#memory-accounting-and-limits)
6. [Large buffers: mmap, page faults, zeroing](#large-buffers)

## Finding allocations

- `perf record -e probe_libc:malloc` or `ltrace -c`, or simply set a
  breakpoint on `malloc` and count.
- heaptrack (`heaptrack ./prog`; `heaptrack_gui`) shows allocation call
  sites and counts; the top "allocations by count" entry in a hot loop is
  the first thing to fix.
- jemalloc's `MALLOC_CONF=prof:true,lg_prof_sample:17` and `jeprof` give a
  sampled allocation profile in production.
- In benchmarks, install a counting `operator new` and assert on the count
  in tests for functions that must not allocate.

## Removing allocations from loops

| Hidden allocation | Fix |
|---|---|
| `std::string s = "literal"` / `std::string(view)` per call | `std::string_view` all the way; build one `std::string` outside the loop |
| `std::vector<T> tmp;` inside the loop body | declare outside, `tmp.clear()` each iteration (capacity stays) |
| returning `std::vector<T>` from a per-element function | take an output `std::vector<T>&`/span to fill, or a callback |
| `std::function` created from a lambda with captures > 2 pointers | template parameter / `absl::FunctionRef` |
| `std::shared_ptr` created per element | create once, pass `const T&` |
| `std::to_string`, `absl::StrCat` per element | write into a preallocated `char` buffer (`absl::numbers_internal::FastIntToBuffer`, `std::to_chars`, `fmt::format_to`) |
| `std::stringstream` | never |
| `std::map`/`std::set`/`std::list` inserts | flat containers, sort once |
| `std::regex` construction | construct once, or use RE2 |
| exception thrown | return code |
| `new T` per node in a tree/graph | arena, or vector + indices |
| `push_back` without `reserve` | `reserve(expected)` |
| `std::vector<std::string>` | offsets + one `chars` buffer |
| `resize(n)` then overwrite | `resize_uninitialized` / default-init allocator |

## Arenas

An arena hands out memory with a bump pointer and frees everything at once.
It suits objects with the same lifetime (all the keys of one aggregation,
all the nodes of one parsed query, all the allocations of one request).

```cpp
class Arena {
 public:
  // Returns `size` bytes aligned to `alignment`; valid until the Arena dies.
  char* Alloc(size_t size, size_t alignment = 8) {
    head_ = Align(head_, alignment);
    if (head_ + size > end_) NewChunk(std::max(size, next_chunk_size_));
    char* result = head_;
    head_ += size;
    return result;
  }
  // ClickHouse also has `allocContinue` to grow the *last* allocation in
  // place, used when serializing a key of unknown length.
 private:
  void NewChunk(size_t size);          // chunks doubling in size, kept in a vector
  char* head_ = nullptr;
  char* end_ = nullptr;
  size_t next_chunk_size_ = 4096;
};
```

Rules:

- Objects in an arena must be trivially destructible, or the arena must
  track destructors (ClickHouse arenas hold only POD and `StringRef` data).
- Size the first chunk from a hint; doubling chunks bound the waste.
- One arena per thread or per task; arenas are not thread-safe and should
  not need to be.
- Use `std::pmr::monotonic_buffer_resource` with `std::pmr::vector` when
  you want standard containers on an arena; `absl::` containers accept
  allocators too.

## Allocators

- **jemalloc** is ClickHouse's default (and most large C++ services'):
  per-thread caches, size classes that reduce fragmentation, background
  purging, and built-in profiling. Link it and set `MALLOC_CONF` (ClickHouse
  disables `muzzy_decay` and tunes `dirty_decay_ms` for its workload).
  `tcmalloc` and `mimalloc` are comparable; glibc `malloc` is measurably
  slower for multithreaded churn.
- For a fixed-size hot object (a node, a request), a free-list pool
  (`boost::pool`, or a hand-rolled intrusive free list) beats general
  `malloc` and keeps objects contiguous.
- Small-buffer optimization (SBO): `absl::InlinedVector<T, N>` and
  `std::string` (SSO ~15/22 bytes) avoid the heap for small sizes. Use
  `InlinedVector` for "usually ≤ N elements".
- Custom `operator new` per class only when a profiler shows that class's
  allocations are hot; comment why.

## Memory accounting and limits

ClickHouse wraps every allocation in a `MemoryTracker`: each query knows
how much it holds, limits are enforced (`max_memory_usage`), and OOM is a
clean error instead of a kernel kill. Practical version for any service:

- Route allocations through an allocator hook (jemalloc `extent_hooks`, or
  a global `operator new` override) that adds to a thread-local counter
  flushed to the query/request-level tracker.
- Track large allocations exactly and small ones in batches to keep the
  atomic traffic low.
- Set soft limits that switch to a spill-to-disk or streaming strategy,
  and hard limits that fail the request.
- Report peak memory per request in logs; regressions are easy to catch.

## Large buffers

- Allocations ≥ ~1 MB come from `mmap` in most allocators: page faults on
  first touch (~0.25 µs per 4 KB page, so 250 ms per GB), and zeroing by
  the kernel. Reuse big buffers instead of freeing and reallocating.
- `MADV_HUGEPAGE` on the buffer cuts page faults 512x and TLB misses.
- `MAP_POPULATE` prefaults if you will touch everything anyway.
- `calloc` and `std::vector::resize` zero memory; if you will overwrite
  it, use uninitialized growth.
- Memory-mapped files: cheap to open, but page faults on random access
  are expensive and unpredictable; ClickHouse prefers explicit reads with
  `O_DIRECT` or its own page cache for the hot path, and `mmap` only for
  cold data. Measure before choosing.
- Free memory back to the OS deliberately (`malloc_trim`, jemalloc
  `purge`) after large temporary peaks; otherwise RSS stays high.
