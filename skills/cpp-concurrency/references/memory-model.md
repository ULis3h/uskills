# Atomics and the memory model, practically

Contents:

1. [What a data race is](#what-a-data-race-is)
2. [Orderings in one table](#orderings-in-one-table)
3. [Patterns that are correct](#patterns-that-are-correct)
4. [Patterns that look correct and are not](#patterns-that-look-correct-and-are-not)
5. [Costs by platform](#costs-by-platform)
6. [Thread-safety annotations](#thread-safety-annotations)

## What a data race is

Two accesses to the same memory location from different threads, at least
one a write, not both atomic, with no happens-before between them. It is
undefined behavior, for `bool` and `int` too. Consequences in practice:
the compiler hoists the read out of your polling loop (infinite loop),
tears a 64-bit write on 32-bit platforms, reorders a flag store before the
data store so the consumer sees the flag but stale data.

Happens-before is created by: mutex unlock → later lock; atomic
store(release) → load(acquire) that reads that value; thread creation →
thread body; thread body → join; `Notification::Notify` →
`WaitForNotification`; future set → `get`; `call_once` completion → later
`call_once`. `std::memory_order_relaxed` creates none.

## Orderings in one table

| Ordering | Guarantees | Use when |
|---|---|---|
| `seq_cst` (default) | acquire+release plus a single global order of all seq_cst ops | default; anything involving more than one atomic; Dekker/Peterson-style protocols |
| `acquire` (loads) | later reads/writes in this thread can't move before this load; sees everything the releasing thread wrote before its release | consumer side of publication (flag, pointer, queue slot) |
| `release` (stores) | earlier reads/writes in this thread can't move after this store | producer side of publication |
| `acq_rel` (RMW) | both | RMW that hands off ownership (refcount decrement that may free, queue CAS) |
| `relaxed` | atomicity only, no ordering | statistics counters, `stop` flags read in a loop where staleness is fine, generating unique ids, the *increment* of a refcount |
| `consume` | don't | (deprecated in practice; compilers upgrade it to acquire) |

Rule: start with `seq_cst`. Downgrade to acquire/release only where the
protocol is exactly "publish data, then flag". Downgrade to relaxed only
where no other memory depends on the value. Comment every non-default
ordering with the reason.

## Patterns that are correct

**Publish an object.**

```cpp
// Producer
auto* obj = new Config(...);           // build fully
published_.store(obj, std::memory_order_release);
// Consumer
if (Config* c = published_.load(std::memory_order_acquire)) Use(*c);   // sees complete Config
```

**Stop flag.**

```cpp
std::atomic<bool> stop_{false};
void Run() { while (!stop_.load(std::memory_order_relaxed)) { DoBatch(); } }   // relaxed: no data depends on it
void Stop() { stop_.store(true, std::memory_order_relaxed); }
// If the loop must see data written before Stop(), use release/acquire instead.
```

**Statistics counter.**

```cpp
std::atomic<uint64_t> bytes_read_{0};
bytes_read_.fetch_add(n, std::memory_order_relaxed);   // no one reasons about ordering vs other data
// For hot counters: shard per thread and sum on read (ClickHouse ProfileEvents does this).
```

**Reference counting.**

```cpp
void AddRef() { count_.fetch_add(1, std::memory_order_relaxed); }   // acquiring a ref needs no ordering
void Release() {
  if (count_.fetch_sub(1, std::memory_order_acq_rel) == 1) delete this;   // last release must see all other threads' writes
}
```

**Swap-a-pointer configuration (read-mostly).**

```cpp
class ConfigHolder {
 public:
  std::shared_ptr<const Config> Get() const {
    absl::MutexLock l(&mu_);      // uncontended lock ~20 ns; or std::atomic<std::shared_ptr>
    return config_;
  }
  void Set(std::shared_ptr<const Config> c) { absl::MutexLock l(&mu_); config_ = std::move(c); }
 private:
  mutable absl::Mutex mu_;
  std::shared_ptr<const Config> config_ ABSL_GUARDED_BY(mu_);
};
```

Readers hold their own `shared_ptr` for the duration of use; no reader
lock needed for the data, and writers never block readers for long.

**Once-initialization.** `absl::call_once(flag, [&] { ... })` or a
function-local static. Don't hand-roll double-checked locking.

**Seqlock for small, frequently read, rarely written data** (only when a
profile shows the mutex): writer increments a sequence to odd, writes,
increments to even; readers read seq, data, seq, retry if odd or changed.
Data must be trivially copyable and the reads use atomics or `memcpy` via
`std::atomic_ref`. Get it from a library.

## Patterns that look correct and are not

- **Two atomics, one invariant.** `size_.store(n); data_[n-1] = x;` read by
  another thread as `if (size_ > 0) use(data_[size_ - 1])`. The invariant
  "size counts written elements" spans two locations; needs a mutex or
  release/acquire on `size_` with the data written *before* the release
  store.
- **Relaxed flag with dependent data.** `ready_.store(true, relaxed)` after
  writing `result_`; the consumer can see `ready_` and stale `result_`.
- **Check-then-act on atomics.** `if (!initialized_) { Init(); initialized_
  = true; }` from two threads: both run `Init`. Use `call_once` or a CAS.
- **`volatile`.** Not atomic, no ordering. Only for memory-mapped I/O and
  signal handlers (`volatile sig_atomic_t`).
- **Assuming x86 semantics.** Code that works on x86 because loads and
  stores are already acquire/release breaks on ARM. Write the orderings
  the protocol needs, and run TSan (it checks the model, not the CPU).
- **Non-atomic `bool` "just for polling".** The compiler may hoist the load
  out of the loop. Data race, UB.
- **`shared_ptr` object mutation.** `shared_ptr`'s *control block* is
  thread-safe; the pointee is not. Two threads mutating `*p` need a lock.
- **`std::atomic<T>` with a non-trivially-copyable or large `T`** compiles
  but uses a lock internally (`is_lock_free()` false), which is a surprise
  in a signal handler or a "lock-free" structure.
- **Fences instead of orderings.** Correct but harder to read; prefer the
  ordering on the operation unless you have a real reason.

## Costs by platform

| Operation | x86-64 | ARM64 |
|---|---|---|
| relaxed load/store | plain mov | plain ldr/str |
| acquire load / release store | plain mov (hardware is TSO) | ldar / stlr (cheap) |
| seq_cst store | mov + mfence or xchg (~20-40 cycles) | stlr (+ dmb on some) |
| seq_cst / acq_rel RMW (fetch_add, CAS) | lock-prefixed instruction, ~20 cycles uncontended, 100s contended | ldaxr/stlxr loop or LSE atomics; similar |
| uncontended mutex lock/unlock | ~20-40 ns (a CAS each) | similar |
| contended mutex | µs (futex syscall) | µs |
| cache line bounce between cores | ~50-100 ns per transfer | similar |

The takeaway: an uncontended atomic RMW is about the same as an
uncontended lock, and both are cheap compared to a cache miss. The
expensive thing is *contention*, so the fix is sharding and batching, not
clever orderings.

## Thread-safety annotations

Clang's `-Wthread-safety` turns locking discipline into compile errors.
Abseil exposes the attributes:

```cpp
class Cache {
 public:
  std::optional<Value> Get(Key k) const ABSL_LOCKS_EXCLUDED(mu_) {
    absl::MutexLock l(&mu_);
    return GetLocked(k);
  }
  void Put(Key k, Value v) ABSL_LOCKS_EXCLUDED(mu_);
 private:
  std::optional<Value> GetLocked(Key k) const ABSL_SHARED_LOCKS_REQUIRED(mu_);
  mutable absl::Mutex mu_;
  absl::flat_hash_map<Key, Value> map_ ABSL_GUARDED_BY(mu_);
  std::unique_ptr<Backend> backend_ ABSL_PT_GUARDED_BY(mu_);   // pointee guarded
};
```

- `ABSL_GUARDED_BY(mu)` on every member touched by more than one thread.
- `ABSL_EXCLUSIVE_LOCKS_REQUIRED(mu)` on private helpers that assume the
  lock is held; `ABSL_LOCKS_EXCLUDED(mu)` on public methods that take it
  (documents "don't call me while holding it").
- `ABSL_ACQUIRED_BEFORE(other_mu)` / `ABSL_ACQUIRED_AFTER` to encode lock
  order; the compiler checks it.
- With `std::mutex`, use the same attributes via `[[clang::guarded_by]]`
  on a wrapper or use `absl::Mutex` directly; it also has deadlock
  detection in debug builds (`absl::EnableMutexInvariantDebugging`,
  `--mutex_deadlock_detection`), `Await` with conditions, and timeouts.
