# Concurrency patterns that scale

Contents:

1. [Thread pool usage](#thread-pool-usage)
2. [Partition, compute, merge](#partition-compute-merge)
3. [Pipelines](#pipelines)
4. [Producer/consumer queues and backpressure](#producer-consumer-queues-and-backpressure)
5. [Cancellation and shutdown](#cancellation-and-shutdown)
6. [Per-thread state](#per-thread-state)
7. [Testing concurrent code](#testing-concurrent-code)

## Thread pool usage

A pool is a fixed set of workers pulling tasks from a queue. Rules that
keep it healthy:

- **One pool for CPU-bound work, sized to cores**; a separate, larger pool
  (or async I/O) for tasks that block on I/O. Mixing them starves CPU work
  behind blocked threads.
- **Never block a pool thread waiting on another pool task** (deadlock when
  all workers wait). Structure as fork/join with the *caller* waiting, or
  use a work-stealing pool that can run the dependency inline.
- **Tasks own their data.** `pool.Schedule([data = std::move(data)] {...})`;
  anything captured by reference must be proven to outlive the task
  (joined via a `BlockingCounter`/`latch` before scope exit).
- **Bounded queue.** An unbounded task queue is a memory leak under load.
  ClickHouse's `ThreadPool` has `max_threads`, `max_free_threads`, and
  `queue_size`; scheduling blocks (or fails) when full.
- **Propagate errors.** Each task returns a `Status` or sets a shared
  `absl::Status` under a mutex (first error wins); the join point checks
  it. Exceptions in a pool task must be captured (`std::exception_ptr`) and
  rethrown at the join, never allowed to escape a worker.
- **Name threads** (`pthread_setname_np`) and propagate context (query id,
  trace span, memory tracker) into tasks so profiles and logs make sense.

```cpp
absl::Status ProcessAll(ThreadPool& pool, absl::Span<const Chunk> chunks) {
  absl::BlockingCounter done(chunks.size());
  absl::Mutex mu;
  absl::Status first_error;                       // ABSL_GUARDED_BY(mu)
  for (const Chunk& c : chunks) {
    pool.Schedule([&] {
      absl::Status s = ProcessChunk(c);           // c outlives the task: we wait below
      if (!s.ok()) { absl::MutexLock l(&mu); first_error.Update(s); }
      done.DecrementCount();
    });
  }
  done.Wait();
  return first_error;
}
```

## Partition, compute, merge

The shape behind nearly every parallel speedup in ClickHouse:

1. **Partition** the input into N independent ranges (blocks, files, key
   ranges). N ≈ 2-4× the number of workers so the tail balances.
2. **Compute** each partition on one thread into thread-private state
   (a local hash table, a local vector, local counters). No shared writes.
3. **Merge** the N partial results. Make the merge parallel too when it is
   large: two-level hash tables (256 buckets by hash prefix; bucket i from
   every partition merges on one thread), tree reduction for sums, k-way
   merge for sorted runs.

```cpp
// Parallel aggregation sketch
std::vector<LocalTable> partials(num_workers);
ParallelFor(chunks, [&](size_t worker, const Chunk& chunk) {
  Aggregate(chunk, &partials[worker]);          // private table per worker
});
// Merge: convert to two-level and merge bucket-wise in parallel
ParallelFor(Range(0, 256), [&](size_t, size_t bucket) {
  for (size_t w = 1; w < num_workers; ++w) partials[0].MergeBucket(bucket, partials[w]);
});
```

Choose partition granularity by cost: too fine and scheduling overhead
dominates (< ~10 µs per task is too small); too coarse and one slow
partition holds everything (use dynamic chunking or work stealing).

## Pipelines

When stages have different costs or different resource types (read →
decompress → parse → filter → aggregate), connect them with bounded queues
and give each stage its own parallelism. Keep the unit of transfer a
*batch* (a block of rows, not a row) so queue overhead is amortized.
ClickHouse's query pipeline is a graph of "processors" with ports that
pull and push blocks; back-pressure is built in because a full output port
stops the producer.

Design notes:

- Preserve ordering only where required (add a sequence number and a
  reordering stage rather than serializing everything).
- Make the slowest stage the widest.
- Use a single-producer/single-consumer queue per edge when possible; it
  is the cheapest kind.

## Producer/consumer queues and backpressure

Mutex + condition variable is fine for < ~1M items/s per queue:

```cpp
template <typename T>
class BoundedQueue {
 public:
  explicit BoundedQueue(size_t capacity) : capacity_(capacity) {}
  // Blocks while full; returns false after Close().
  bool Push(T item) ABSL_LOCKS_EXCLUDED(mu_) {
    absl::MutexLock l(&mu_);
    mu_.Await(absl::Condition(+[](BoundedQueue* q) { return q->closed_ || q->items_.size() < q->capacity_; }, this));
    if (closed_) return false;
    items_.push_back(std::move(item));
    return true;
  }
  std::optional<T> Pop() ABSL_LOCKS_EXCLUDED(mu_) {
    absl::MutexLock l(&mu_);
    mu_.Await(absl::Condition(+[](BoundedQueue* q) { return q->closed_ || !q->items_.empty(); }, this));
    if (items_.empty()) return std::nullopt;   // closed and drained
    T t = std::move(items_.front()); items_.pop_front();
    return t;
  }
  void Close() ABSL_LOCKS_EXCLUDED(mu_) { absl::MutexLock l(&mu_); closed_ = true; }
 private:
  absl::Mutex mu_;
  std::deque<T> items_ ABSL_GUARDED_BY(mu_);
  bool closed_ ABSL_GUARDED_BY(mu_) = false;
  const size_t capacity_;
};
```

Beyond that, use a vetted lock-free MPMC queue (folly, moodycamel, or the
project's). Batch pushes and pops (a vector of items per operation)
before reaching for lock-free.

Backpressure: bounded queues make the producer block, which is correct;
"drop on full" is acceptable only for telemetry. Unbounded queues turn
overload into OOM.

## Cancellation and shutdown

- **Cooperative cancellation**: tasks check a `std::stop_token` /
  `std::atomic<bool>` at batch boundaries. Blocking waits take a deadline
  or are woken by `Close()` on their queue / `Notify()` on a notification.
- **Order of teardown** in a destructor: (1) set stop flag, (2) close
  queues / cancel timers, (3) join threads, (4) destroy members. Declare
  the thread or pool as the *last* member so default destruction order
  already does (3) before (4), and still do (1)-(2) explicitly.
- **In-flight callbacks**: cancelling a timer or subscription must either
  wait for a running callback to finish or guarantee the callback holds a
  strong reference to what it touches.
- **Never `detach`.** A detached thread that outlives `main` or its data
  is a crash at exit.
- **Global shutdown**: stop accepting work, drain, then stop workers; log
  the counts. Don't rely on `atexit` order for anything threaded.

## Per-thread state

- `thread_local` for caches and scratch buffers that are hot and small;
  note that TLS access can be a function call in shared libraries and
  destructors run at thread exit in unspecified order relative to other
  thread-locals.
- Explicit `std::vector<State> per_worker(num_workers)` indexed by worker
  id is simpler, testable, and lets the merge step iterate it. Pad each
  `State` to a cache line.
- Random number generators, arenas, and allocator caches belong per
  thread; a shared `std::mt19937` under a lock is a classic bottleneck.

## Testing concurrent code

- Write the sequential implementation first; use it as the oracle:
  `EXPECT_EQ(ParallelSum(v), SequentialSum(v))` over random inputs.
- Stress tests: many threads × many iterations × small critical sections,
  with `std::this_thread::yield()` or short random sleeps injected at
  interesting points, so interleavings vary. Run under TSan; TSan finds
  races even if the test's assertions pass.
- Use `absl::Notification` / `std::latch` to force specific interleavings
  ("thread A has entered the critical section, now thread B tries") rather
  than sleeps.
- Deadlock tests run with a timeout wrapper so a hang is a failure, not a
  stuck CI job.
- Check invariants under contention: counts add up, no item lost or
  duplicated through the queue, resources freed exactly once (count
  constructions and destructions).
- Test shutdown while busy: start work, destroy the object, ASan/TSan
  must be silent.
- Run the concurrent test suite with `--gtest_repeat=100` nightly; a race
  that shows once in 50 runs is real.
