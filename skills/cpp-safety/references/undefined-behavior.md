# Undefined behavior catalog

For each: what it is, how it usually manifests, how to detect, how to fix.
UB is not "the program crashes"; it is "the optimizer assumes this never
happens", so the symptom is often a deleted check, a loop that runs
forever, or a wrong value far from the cause.

Contents:

1. [Memory](#memory)
2. [Integers](#integers)
3. [Objects and types](#objects-and-types)
4. [Control flow and language rules](#control-flow-and-language-rules)
5. [Library preconditions](#library-preconditions)
6. [Concurrency](#concurrency)

## Memory

**Out-of-bounds read/write.** `a[i]` with `i >= size`, including `i == size`
and `str[str.size()]` for writes. Manifests as corruption, "impossible"
values, crashes in unrelated code. Detect: ASan, hardened stdlib. Fix:
bounds check from input, iterate over `size()`, use `span`.

**Use after free / use after scope.** Pointer, reference, `string_view`,
iterator to a destroyed object. Manifests as garbage or a crash that moves
with allocator behavior. Detect: ASan (`heap-use-after-free`,
`stack-use-after-scope`, `stack-use-after-return` with
`ASAN_OPTIONS=detect_stack_use_after_return=1`). Fix: see `lifetimes.md`.

**Double free / mismatched allocation.** `delete` of a `new[]`, `free` of
`new`, deleting twice. Detect: ASan. Fix: `unique_ptr`, containers.

**Null dereference.** Detect: UBSan `-fsanitize=null`, `-Wnull-dereference`.
Fix: references or `absl::Nonnull` for non-null contracts; `optional` /
`StatusOr` for maybe-absent; `CHECK(p != nullptr)` at the boundary.

**Uninitialized read.** `int x; if (x)`, a struct member never set,
`std::vector<T>` grown with a default-init allocator then read. Manifests as
nondeterminism, "works in debug". Detect: MSan (requires all code including
libc++ instrumented), `-Wuninitialized`, `-ftrivial-auto-var-init=pattern`
in test builds to make it deterministic garbage. Fix: initialize at
declaration; default member initializers.

**Misaligned access.** `*reinterpret_cast<uint32_t*>(char_ptr + 1)`. Works on
x86, faults on some ARM, and is UB everywhere (and blocks vectorization
assumptions). Detect: UBSan `-fsanitize=alignment`. Fix: `memcpy` into a
local or `std::bit_cast` from a `std::array<char, N>`; the compiler emits a
single unaligned load where the platform allows.

**Strict aliasing violation.** Accessing an object through a pointer of an
unrelated type (`float f; *(uint32_t*)&f`). Manifests as stale values after
optimization. Detect: hard (no sanitizer); `-Wstrict-aliasing`. Fix:
`std::bit_cast`, `memcpy`, or `char`/`std::byte` pointers (which may alias
anything). Do not "fix" with `-fno-strict-aliasing` in new code.

**Pointer arithmetic outside an array.** `p + n` beyond one-past-the-end,
comparing pointers into different arrays with `<`. Detect: UBSan
`pointer-overflow`. Fix: index arithmetic on `size_t`, compare only within
the same array.

**Stack overflow.** Deep recursion, huge local arrays, `alloca`. Manifests as
SIGSEGV with a stack trace thousands deep or with no trace at all. Detect:
ASan reports `stack-overflow`; `ulimit -s` to shrink the stack in tests.
Fix: depth limit on untrusted input, iterate with an explicit stack, move
large buffers to the heap.

## Integers

**Signed overflow.** `int32_t x = INT32_MAX; x + 1`. The optimizer assumes it
cannot happen, so `if (x + 1 < x)` is deleted. Detect: UBSan
`-fsanitize=signed-integer-overflow`. Fix: `__builtin_add_overflow`,
wider type, `absl::int128`, explicit range check before the operation.

**Unsigned wraparound.** Defined, but `size_t n = 0; n - 1` is `SIZE_MAX`
and `for (size_t i = n - 1; i >= 0; --i)` never ends. Detect: UBSan
`-fsanitize=unsigned-integer-overflow` (noisy; enable per-file), code
review. Fix: rewrite comparisons so subtraction cannot underflow; loop
`for (size_t i = n; i-- > 0;)`.

**Shift UB.** `1 << 32` on 32-bit int, shift by negative, left shift of a
negative value. Detect: UBSan `shift`. Fix: `uint64_t{1} << n` with `n <
64` checked, `std::rotl`.

**Division by zero, `INT_MIN / -1`, `%` by zero.** Detect: UBSan
`integer-divide-by-zero`. Fix: check the divisor when it comes from data.

**Float to int out of range.** `static_cast<int>(1e20)` or of NaN. Detect:
UBSan `float-cast-overflow`. Fix: clamp first, check `std::isfinite`.

**Narrowing.** `int len = str.size();` then `len < 0` on 3 GB input. Not UB by
itself, but leads to negative sizes and OOB. Detect: `-Wconversion`,
`-Wshorten-64-to-32`. Fix: `size_t`, explicit checked cast.

**Implicit promotion surprises.** `uint8_t a = 200, b = 100; auto c = a + b;`
is `int` 300 (fine), but `uint8_t c = a + b` is 44. `uint16_t x; x * x` is
computed as `int` and can overflow for `x > 46340` (UB). Fix: cast to the
intended width before arithmetic.

## Objects and types

**Use of a moved-from object** other than assignment or destruction.
Manifests as empty strings or vectors where data was expected. Detect:
`clang-tidy bugprone-use-after-move`. Fix: move only at the last use.

**Object lifetime not started / ended twice.** Placement `new` without
matching explicit destructor call, `memcpy` of non-trivially-copyable
types, reading a union member not last written. Detect: review, ASan for
some. Fix: `std::variant`, `std::construct_at`/`std::destroy_at`, restrict
`memcpy` to `std::is_trivially_copyable` types with a `static_assert`.

**Virtual call during construction/destruction** dispatches to the base
version (not UB, but a bug); calling a pure virtual there is UB. Fix:
factory function that calls the virtual after construction.

**Missing virtual destructor** deleting a derived object through a base
pointer. Detect: `-Wnon-virtual-dtor`, `-Wdelete-non-virtual-dtor`. Fix:
`virtual ~Base() = default;` or make the base destructor protected.

**Invalid downcast.** `static_cast<Derived*>(base)` when it isn't a
`Derived`. Detect: UBSan `-fsanitize=vptr` (needs RTTI). Fix: `dynamic_cast`
+ check, or a type tag.

**Invalid enum value.** Casting 7 into an enum whose enumerators are 0..3
with no fixed underlying type; then `switch` without matching case.
Detect: UBSan `enum`. Fix: give the enum a fixed underlying type and
validate before casting.

**ODR violation.** The same class defined differently in two TUs (different
`#define`s, different `NDEBUG`, different versions of a header), inline
functions with different bodies, a template specialized in one TU only.
Manifests as bizarre crashes, wrong virtual function called, `sizeof`
mismatch. Detect: ASan `detect_odr_violation=2`, `-Wodr` with LTO. Fix: one
definition, consistent flags across all TUs and libraries, no
configuration macros in headers that affect layout.

**Static initialization order fiasco.** A global in one TU uses a global in
another during construction. Detect: ASan `check_initialization_order=1`,
`-Wglobal-constructors`. Fix: no non-trivial globals; function-local
statics (`static const T& Get() { static const T* t = new T; return *t; }`).

**Returning without a value** from a non-void function. Detect:
`-Wreturn-type` as error, UBSan `return`. Fix: obvious.

## Control flow and language rules

**Infinite loop without side effects** may be assumed to terminate (before
C++26). Fix: don't rely on it; use `std::atomic` or a volatile-ish sink if
you really need a spin.

**Modifying a `const` object** via `const_cast`. Fix: don't; use `mutable`
with a lock for caches.

**Unsequenced modifications.** `i = i++ + 1`, `f(i++, i++)` (unspecified
order). Detect: `-Wsequence-point`, `-Wunsequenced`. Fix: separate
statements.

**Reading `errno` after a successful call**, or using `strerror` (not
thread-safe). Fix: check the return first; `strerror_r`, `absl::StrError`.

**Calling a function through a pointer of the wrong type**, e.g. passing a
C++ lambda with captures as a C function pointer. Fix: captureless lambda
converts; otherwise trampoline with `void* user_data`.

**`std::string_view` from a `nullptr`** (`string_view(nullptr)` is UB;
`string_view()` is fine). Check `const char*` from C APIs before wrapping.

**`va_arg` type mismatch**, `printf` format mismatch. Detect: `-Wformat=2`,
use `absl::StrFormat`/`fmt` (compile-time checked).

## Library preconditions

Violating these is UB in the standard, and hardened builds turn them into
crashes:

- `v.front()`, `v.back()`, `v[i]`, `*v.begin()` on an empty container.
- `std::optional::operator*` when empty; `absl::StatusOr::operator*` when
  not ok.
- `std::sort` with a comparator that is not a strict weak ordering (e.g.
  `<=`, or comparing floats with NaN). Manifests as OOB inside `sort`.
  Fix: `<`, handle NaN explicitly; `std::sort` with a comparator that is
  consistent.
- `std::lower_bound` on unsorted data.
- `std::string::substr(pos)` with `pos > size()` throws; `string_view::
  substr` too, but `string_view::remove_prefix(n)` with `n > size()` is UB.
- `std::memcpy` with overlapping ranges (use `memmove`); with a null
  pointer even for zero length (defined only from C++26/C23; check).
- `std::vector::reserve` then writing through `data()` beyond `size()`.
- `std::shared_ptr` from a raw pointer twice; `shared_from_this` before
  a `shared_ptr` owns the object.
- `std::thread` destroyed while joinable (`std::terminate`); use
  `std::jthread` or join in a destructor.
- `std::mutex` unlocked by a thread that doesn't own it; destroyed while
  locked.
- `std::atomic` non-lock-free used from a signal handler.
- Format strings from user input.

## Concurrency

**Data race.** Two threads access the same location, at least one writes,
without synchronization. UB even for a `bool`. "Benign" races get
miscompiled (the read hoisted out of the loop). Detect: TSan. Fix: mutex,
`std::atomic`, or confine to one thread. See `cpp-concurrency`.

**Deadlock** is not UB but is fatal. Detect: TSan lock-order inversion
report, `absl::Mutex` deadlock detection in debug builds. Fix: lock
ordering, `std::scoped_lock` for multiple locks, never hold a lock across
unknown code.

**Signal handler** calling non-async-signal-safe functions (`malloc`,
`printf`, locks). Fix: set a `volatile sig_atomic_t` or `std::atomic` flag,
write to a pipe; do real work elsewhere.
