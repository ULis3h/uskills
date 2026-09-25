---
name: cpp-concurrency
description: Write correct and scalable multithreaded C++: mutexes with thread-safety annotations, atomics and memory ordering, thread pools and task parallelism, partition-then-merge instead of shared state, false sharing, lock-free only when measured, cancellation and shutdown, TSan-driven testing. Use this skill whenever C++ code creates threads, uses std::thread/jthread/async, a thread pool, mutexes, condition variables, atomics, spinlocks, futures/promises, coroutines, or shared caches; whenever the user mentions race conditions, deadlocks, contention, "thread-safe", parallelism, scaling across cores, TSan, or a bug that only appears under load; and when reviewing any code that shares state across threads.
---

# C++ concurrency

The reliable way to write concurrent C++, as practiced in Abseil and
ClickHouse: **share as little as possible, protect what you share with a
mutex and say so in the type, partition work so threads don't touch the
same cache lines, and treat every unsynchronized access as a bug (because
it is UB).** Atomics and lock-free structures are specialist tools used
after a profile shows the lock, never before.

Reference files:

- `references/memory-model.md`: atomics, memory orderings, when relaxed is
  right, fences, and the patterns (flags, counters, seqlocks, publication)
  that are actually safe.
- `references/patterns.md`: thread pools, parallel aggregation and merge,
  pipelines, producer/consumer queues, cancellation, shutdown ordering, and
  testing with TSan.

## 1. Design rules

1. **Confine first.** The best synchronization is none: each thread owns
   its data; results are combined at a join point. ClickHouse aggregates
   into per-thread hash tables and merges at the end rather than sharing one
   table under a lock.
2. **Immutable is thread-safe.** Data built once and never mutated can be
   shared freely (`const`, `shared_ptr<const T>`). Copy-on-write /
   swap-a-pointer beats a read-write lock for read-mostly configuration.
3. **Every mutable shared variable has exactly one lock, named in the
   declaration**: `absl::Mutex mu_; int count_ ABSL_GUARDED_BY(mu_);`. Build
   with clang `-Wthread-safety` so forgetting the lock is a compile error.
4. **Critical sections are short and call nothing unknown.** No callbacks,
   no virtual calls into other components, no I/O, no allocation-heavy work
   while holding a lock. Copy what you need out under the lock, then work.
5. **Lock order is global and documented.** If two locks are ever held
   together, the order is fixed and written in a comment near the mutexes;
   acquire several at once with `std::scoped_lock`.
6. **Condition variables always use a predicate.** `absl::Mutex::Await(
   absl::Condition(&ready))` or `cv.wait(lock, [&] { return ready; })`;
   spurious wakeups are a fact.
7. **Atomics are for one variable, not for protocols.** A `std::atomic`
   protects one word. Two atomics that must be consistent with each other
   need a mutex (or a proven publication pattern from the reference).
8. **Thread pools, not threads.** Creating a thread is ~50 µs and unbounded
   thread creation is a DoS vector. Use the project's pool; size it to the
   hardware; give tasks a bounded queue with backpressure.
9. **Shutdown is designed, not hoped for.** Every thread has an owner that
   joins it; every blocking wait has a way to be cancelled; destructors
   stop and join before members are destroyed (declare threads *last* so
   they are destroyed *first*).
10. **Test under TSan** with tests that actually run threads concurrently
    (many iterations, small critical sections, yields) and run them in CI.

## 2. Choosing a primitive

| Situation | Use |
|---|---|
| Protect a struct's invariants | `absl::Mutex` (or `std::mutex`) + `ABSL_GUARDED_BY` |
| Wait for a condition | `absl::Mutex::Await` / `std::condition_variable` with predicate |
| One-time init | `absl::call_once` / function-local static |
| Signal "done" once | `absl::Notification` / `std::latch` / `std::promise` |
| Wait for N tasks | `absl::BlockingCounter` / `std::latch` |
| Counter or flag read often, written rarely | `std::atomic<T>` with documented ordering |
| Read-mostly data updated wholesale | `std::shared_ptr<const T>` swapped under a mutex (or `std::atomic<std::shared_ptr>`), readers copy the pointer |
| Read-heavy, long critical sections, rare writes | `absl::Mutex` reader lock, only after measuring (ToTW 197: reader locks are often slower) |
| Hand-off between threads | bounded MPMC queue (the project's, `absl` has none; `moodycamel`, `folly::MPMCQueue`, or mutex+cv) |
| Per-thread scratch | `thread_local` (watch destructor order and cost on some platforms) or explicit per-worker state indexed by worker id |
| Spinning | almost never; if you must, bounded spin with `pause`, then block |
| Lock-free structure | only from a vetted library, only after a profile shows the lock, only with a written proof of the protocol |

## 3. Performance under concurrency

- **False sharing** is the number-one scaling bug: two threads writing
  different variables on the same 64-byte line serialize on the cache
  coherence protocol. Pad per-thread counters
  (`alignas(std::hardware_destructive_interference_size)`), never put
  per-thread state in adjacent array slots. `perf c2c` finds it.
- **Contention** on one atomic or lock scales worse than linearly. Shard
  by thread or by hash (N counters summed on read; N locks selected by
  key hash; per-thread hash tables merged at the end).
- **`std::shared_ptr` copies** are atomic increments on a shared line;
  pass `const T&` inside a thread and copy the `shared_ptr` only when
  crossing a lifetime boundary.
- **Reader-writer locks** bounce the cache line on every reader acquire;
  they beat a plain mutex only when reads are long. Measure.
- **Oversubscription**: more runnable threads than cores costs context
  switches and cache thrash. Size pools to `hardware_concurrency()` for
  CPU work; use separate, larger pools for blocking I/O; or use async I/O.
- **NUMA**: on multi-socket machines, allocate memory on the thread that
  will use it (first-touch) and pin worker threads.
- **Batch across the boundary**: push 1000 items into a queue in one lock
  acquisition, not 1000 acquisitions.
- **Memory ordering** costs little on x86 (loads/stores are already
  acquire/release) and more on ARM; seq_cst RMW is a full barrier
  everywhere. Prefer correctness; optimize orderings only inside a
  profiled hot spot.

## 4. Things that are always wrong

- A non-atomic variable read by one thread and written by another with no
  lock ("it's just a bool"). Data race, UB, will be miscompiled.
- `volatile` for synchronization.
- Double-checked locking without an atomic acquire load.
- Holding a lock while calling a user callback or a virtual method on an
  object you don't own.
- Detached threads (`std::thread::detach`) touching anything with a
  lifetime.
- `sleep` to "let the other thread finish".
- Busy-wait spinning on a plain variable.
- Locking in a destructor of a global (shutdown order) or in a signal
  handler.
- `std::async` without a stored future (it blocks in the temporary's
  destructor).
- A condition variable notified without holding the mutex that protects
  the predicate (lost wakeup), or waited on without a predicate.
- Time-based tests for concurrency ("wait 100 ms then assert"). Use
  notifications and counters.

## 5. Workflow

1. Draw the ownership: which thread owns which data; where data crosses
   threads. Prefer transferring ownership (`std::move` into the task) to
   sharing.
2. For each shared mutable object: pick the lock, annotate every guarded
   member, and write the lock order comment.
3. Write the sequential version first and keep it as the oracle for
   tests.
4. Parallelize with the pool + partition + merge shape from
   `references/patterns.md`.
5. Write a stress test (many threads, many iterations, randomized
   yields) and run it under TSan and ASan.
6. Profile with `perf` and `perf c2c`; fix false sharing and contention
   before touching memory orderings.
