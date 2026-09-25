---
name: cpp-safety
description: Write memory-safe, UB-free, robust C++: lifetimes and dangling views, ownership discipline, integer overflow and conversions, bounds, iterator invalidation, exception and thread safety, plus the tooling that proves it (ASan/UBSan/TSan/MSan, hardened standard library, warnings-as-errors, clang-tidy, fuzzing). Use this skill whenever C++ code touches raw pointers, references, string_view/span, indices, casts, integer arithmetic, manual memory, unions, or untrusted input; whenever the user mentions a crash, segfault, use-after-free, memory leak, corruption, sanitizer report, undefined behavior, "flaky" test, or security hardening; and when reviewing or debugging any C++ bug whose cause is unclear. Also use it to set up sanitizer or fuzzing builds.
---

# C++ safety

Safe C++ is a discipline, not a feature. The language will compile dangling
references, signed overflow, and out-of-bounds writes without complaint and
the optimizer will then assume they never happen. The approach that works,
used by both Abseil and ClickHouse: **make the safe thing the default in the
code (types, RAII, value semantics), enforce invariants with checks that
stay on in production where cheap, and run every test under sanitizers and
fuzzers so the remaining bugs surface before users find them.**

Reference files:

- `references/undefined-behavior.md`: catalog of UB and how each shows up,
  with the fix. Read when diagnosing a crash or reviewing tricky code.
- `references/lifetimes.md`: dangling references, views, iterators, and
  lambdas; rules for storing non-owning handles.
- `references/tooling.md`: exact compiler flags, sanitizer setup, hardened
  stdlib, clang-tidy checks, libFuzzer harness template, CI matrix.

## 1. Ownership and lifetime rules

1. **Every object has exactly one owner**, expressed in the type:
   `std::unique_ptr<T>`, a container, or a value member. `T*` and `T&`
   never own. `std::shared_ptr` only when lifetime is genuinely shared and
   a comment explains by whom.
2. **A non-owning handle (`T*`, `T&`, `string_view`, `span`, iterator,
   reference-capturing lambda) must not outlive its owner.** If you store
   one in a member, write the lifetime guarantee in the class comment and
   make the owner's lifetime enforceable (the owner outlives `this` by
   construction, e.g. it is passed to the constructor and owned by the
   parent). If you cannot state the guarantee, copy the data instead.
3. **Never return a reference or view to a local or to a temporary**, and
   never bind one to the result of a function that returns by value.
4. **Moved-from objects are valid but unspecified.** Only assign to or
   destroy them. `std::move` a name only when it is the last use.
5. **Iterators and references into containers die on mutation.** For
   `std::vector` any insert/erase/`push_back` beyond capacity; for
   `absl::flat_hash_map` any insert; for `std::deque` anything but
   push/pop at ends. Restructure loops so mutation happens after iteration,
   or use indices.
6. **RAII for every resource**: memory, file descriptors, locks, sockets,
   handles, transactions. Cleanup code that is not in a destructor will be
   skipped by some early return or exception.

## 2. Values, types, and conversions

- Prefer value types and `std::optional<T>`, `std::variant`, `absl::StatusOr`
  over pointers-that-might-be-null.
- Use `enum class` with an explicit underlying type when stored; validate
  before casting an integer to an enum (an out-of-range value is UB for
  enums without a fixed type, and a logic bug otherwise).
- Casts: `static_cast` for numeric and up/down class conversions you know
  are valid; `std::bit_cast` for reinterpreting bits (never `reinterpret_cast`
  through a pointer of another type, which violates aliasing rules);
  `absl::implicit_cast` to make an implicit conversion explicit; never
  C-style casts, never `const_cast` away real const.
- Narrowing conversions (`int64_t` → `int32_t`, `double` → `int`,
  `size_t` → `int`) are bugs waiting for large inputs. Use brace-init to
  make them compile errors, check the range explicitly (`std::in_range`,
  a `CHECK`), or use a saturating cast. Enable `-Wconversion
  -Wsign-conversion`.
- Signed/unsigned: keep loop indices and sizes `size_t`; keep arithmetic
  that can go negative signed; never compare signed with unsigned; write
  `if (i + 1 < n)` not `if (i < n - 1)` when `n` may be 0.
- `bool` is not an integer. `enum` is not an integer. Don't do arithmetic
  on them.

## 3. Integer arithmetic

- **Signed overflow is UB**; unsigned wraps silently. Both are bugs unless
  intended. For sizes and offsets from untrusted input, check with
  `__builtin_add_overflow`/`__builtin_mul_overflow` (or
  `absl::int128`) before allocating or indexing.
- Compute `a + b` for lengths only after checking `a <= kMax - b`.
- Shifts: `x << n` with `n >= bit_width` or negative is UB; shifting a
  negative signed value is UB (left) or implementation-defined (right).
  Mask the shift count or use `std::rotl`.
- Division by zero and `INT_MIN / -1` are UB. Check divisors from input.
- Use `std::size_t` for byte counts, `std::ptrdiff_t` for differences,
  fixed-width types for wire and storage formats.
- Floating point: never compare with `==` for computed values; check for
  NaN before using as an index or key; avoid `-ffast-math` in code that
  handles infinities or NaN deliberately.

## 4. Bounds and memory

- Index only after a bounds check, unless the index is provably in range by
  construction (loop over `size()`). Prefer range-for, `std::span`,
  algorithms, and `absl::Span` to raw pointer arithmetic.
- Bounds checks that guard against untrusted input are correctness code,
  not debug code: keep them in release. Bounds checks that guard internal
  invariants can be `DCHECK` plus hardened-stdlib assertions.
- Never `memcpy` into a buffer without first checking the length against
  the destination's size; never `strcpy`, `sprintf`, `gets`, `strcat`.
  Use `absl::StrCat`, `snprintf` with size, `std::string`.
- Unions: read only the member last written (or use `std::variant`).
  Type punning goes through `std::bit_cast` or `memcpy`.
- Alignment: never cast a `char*` to `uint32_t*` and dereference; use
  `memcpy` into a local (the compiler emits one load).
- Uninitialized reads: initialize every scalar at declaration; default
  member initializers for every member; `-ftrivial-auto-var-init=zero` as a
  belt-and-braces hardening flag in release builds; MSan finds the rest.
- Stack: no large arrays on the stack (`char buf[1 << 20]`), no
  variable-length arrays, no `alloca` with untrusted sizes. Recursion over
  untrusted input needs a depth limit.

## 5. Exceptions, errors, and invariants

- Every function is at least *basic* exception safe (no leaks, invariants
  hold) by construction if you use RAII and no raw resource handling.
  Provide the *strong* guarantee (all-or-nothing) for mutations of data
  structures where a half-applied change is worse than failure; the
  copy-and-swap idiom is the standard way.
- `noexcept` on destructors (implicitly), move operations, `swap`, and
  functions called from destructors; `std::vector` will copy instead of
  move a type whose move can throw.
- Check every `Status`, every return code, every `errno`. Ignoring one
  requires a comment.
- Enforce preconditions at API boundaries with `CHECK` (crash with a
  message) rather than continuing in a corrupted state: a controlled abort
  is safer than memory corruption.
- Validate untrusted input completely at the trust boundary (length,
  range, encoding, nesting depth, total size), then treat it as trusted
  inside. Don't sprinkle half-checks through the internals.

## 6. Concurrency safety (summary; details in `cpp-concurrency`)

- Every piece of mutable shared state has a documented lock or is confined
  to one thread. Use `ABSL_GUARDED_BY` annotations and
  `-Wthread-safety`.
- A data race is UB, not a "benign race". If two threads touch a variable
  and one writes, it needs a mutex or `std::atomic`.
- Never call unknown code (callbacks, virtuals) while holding a lock.
- Run the tests under TSan.

## 7. Tooling that must be on (details in `references/tooling.md`)

- Warnings: `-Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
  -Wold-style-cast -Wnon-virtual-dtor -Woverloaded-virtual
  -Wnull-dereference -Wimplicit-fallthrough -Werror` (project may need to
  phase them in).
- Sanitizers in CI: ASan+UBSan build, TSan build, and MSan where feasible.
  `-fno-sanitize-recover=all` so the first error fails the test.
- Hardened standard library in debug and test builds: libc++
  `_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG`, libstdc++
  `-D_GLIBCXX_ASSERTIONS`, Abseil `ABSL_HARDENED`. Consider the fast
  hardening mode in production; the cost is usually a few percent.
- `clang-tidy` with `bugprone-*`, `cert-*`, `cppcoreguidelines-*`,
  `misc-*`, `performance-*` (see the config in `cpp-project-setup`).
- Fuzz every parser and every function that takes untrusted bytes with
  libFuzzer; ClickHouse fuzzes its SQL parser, its AST, and its formats
  continuously and still finds bugs.
- Static analysis (`clang --analyze`, `scan-build`) on the CI once a day.

## 8. Diagnosing a crash or corruption

1. Reproduce under ASan+UBSan first; nine times out of ten the report names
   the line. Then TSan if threads are involved; MSan if the value seems
   random.
2. If the sanitizer is silent, check for: moved-from use, iterator
   invalidation, stack overflow (deep recursion, huge locals), ODR violation
   (two definitions of a class with different layouts, mismatched
   `NDEBUG`/flags across TUs), static initialization order, mismatched
   `new[]`/`delete`, a `string_view` into a temporary.
3. Bisect the input with the fuzzer's minimizer or `creduce`; bisect the
   commit with `git bisect run`.
4. Fix the root cause, add a regression test with the minimized input, and
   run the whole suite under sanitizers again.

## 9. Never

- Raw `new`/`delete`, `malloc`/`free` outside allocator code.
- Owning raw pointers, `T*` returned from a factory.
- `reinterpret_cast` between unrelated pointer types followed by a
  dereference.
- Suppressing a sanitizer or compiler warning without a comment explaining
  why it is a false positive and a link to the issue.
- Catch-all `catch (...)` that swallows and continues.
- "This can't overflow" without a `static_assert`, a `CHECK`, or a
  documented bound.
- Sleeping to fix a race.
