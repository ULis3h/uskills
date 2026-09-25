# C++ review checklist

Tick through every section for a non-trivial change. Items are phrased as
questions whose "yes" is a finding. Severity hints in brackets.

Contents:

1. [Correctness and undefined behavior](#1-correctness-and-undefined-behavior)
2. [Ownership and lifetime](#2-ownership-and-lifetime)
3. [Error handling](#3-error-handling)
4. [Concurrency](#4-concurrency)
5. [API design and readability](#5-api-design-and-readability)
6. [Performance (hot paths only)](#6-performance-hot-paths-only)
7. [Tests](#7-tests)
8. [Build, dependencies, hygiene](#8-build-dependencies-hygiene)
9. [Security-sensitive code](#9-security-sensitive-code)

## 1. Correctness and undefined behavior

- [ ] Any index without a bounds guarantee? `v[i]` where `i` comes from
      input, arithmetic, or a different container's size? `[BLOCKER]`
- [ ] `front()/back()/[0]/*begin()` on a possibly empty container? `[BLOCKER]`
- [ ] Signed arithmetic that can overflow (sizes, offsets, timestamps
      multiplied, `int` accumulators over large inputs)? `[BLOCKER]`
- [ ] Unsigned subtraction that can wrap (`size() - 1`, `end - begin`
      where `end < begin` is possible)? `[BLOCKER]`
- [ ] Narrowing conversions (`size_t` → `int`, `int64` → `int32`,
      `double` → integer) without range checks? `[MAJOR]`
- [ ] Shift by ≥ width or negative; division by a value that can be 0?
      `[BLOCKER]`
- [ ] Use after `std::move`? (grep for the moved name after the move)
      `[BLOCKER]`
- [ ] Iterator/reference/pointer held across an insert/erase/push_back
      on the same container? `[BLOCKER]`
- [ ] `reinterpret_cast` between unrelated types and then a dereference;
      unaligned loads; union punning? `[BLOCKER]`
- [ ] Uninitialized members or locals (no default member initializer,
      `T t;` of a scalar)? `[MAJOR]`
- [ ] Non-exhaustive `switch` over an enum, or a `default:` that hides
      new enumerators? `[MAJOR]`
- [ ] Off-by-one at loop bounds, half-open vs closed ranges, `<=` vs `<`?
      `[BLOCKER]`
- [ ] Comparison function that is not a strict weak ordering (`<=`, NaN,
      inconsistent tie-breaking)? `[BLOCKER]`
- [ ] Floating-point equality; NaN reaching an index or hash key? `[MAJOR]`
- [ ] Static/global with a non-trivial constructor depending on another
      global? `[MAJOR]`
- [ ] Virtual call in a constructor/destructor; missing virtual destructor
      on a base deleted polymorphically? `[BLOCKER]`
- [ ] Missing `return` on some path (compiler warning suppressed)?
      `[BLOCKER]`
- [ ] Logic only correct for the happy path (empty input, single element,
      duplicates, maximum sizes)? `[MAJOR]`

## 2. Ownership and lifetime

- [ ] Raw pointer that owns (`new` without `unique_ptr`; `T*` returned from
      a factory; `delete` in code)? `[BLOCKER]`
- [ ] `string_view`/`Span`/`const T&`/`T*` stored in a member or a
      long-lived struct: is the owner's lifetime guaranteed and documented?
      `[BLOCKER if not]`
- [ ] View or reference bound to a temporary (`string_view v = F();` with
      `F` returning `std::string`; `const auto& x = Make().field()`)?
      `[BLOCKER]`
- [ ] Lambda capturing `[&]` or `this` that is stored, scheduled, or
      returned? `[BLOCKER]`
- [ ] Callback/observer registered without a matching unregister on
      destruction? `[BLOCKER]`
- [ ] `shared_ptr` used where a single owner exists (design smell) or
      `shared_ptr` cycles (leak)? `[MAJOR]`
- [ ] Parameter taken as `const std::string&`/`const std::vector&` and
      then copied into a member (should be by value + move)? `[MINOR]`
- [ ] Parameter `string_view` but the callee stores it? `[BLOCKER]`
- [ ] Thread or task referencing stack data not joined before scope exit?
      `[BLOCKER]`
- [ ] Rule of zero/five violated: custom destructor without deleted/defined
      copy and move? `[MAJOR]`
- [ ] Move constructor/assignment not `noexcept` on a type stored in
      `std::vector`? `[MINOR]`

## 3. Error handling

- [ ] A `Status`, return code, `errno`, or `bool` result ignored? `[BLOCKER]`
- [ ] Failure reported as `bool`/`-1`/`nullptr`/empty with no reason?
      `[MAJOR]`
- [ ] Wrong canonical code (e.g. `Internal` for bad user input)? `[MINOR]`
- [ ] Error message lacks the offending value or location? `[MINOR]`
- [ ] Precondition violation handled as a runtime error, or a runtime
      condition handled as a `CHECK` crash? `[MAJOR]`
- [ ] Exception thrown across a destructor, a `noexcept` function, a C
      boundary, or on a hot path? `[BLOCKER]`
- [ ] `catch (...)` that swallows? `[BLOCKER]`
- [ ] Cleanup that runs only on the success path (not RAII)? `[MAJOR]`
- [ ] Partial mutation left behind on failure where callers expect
      all-or-nothing? `[MAJOR]`

## 4. Concurrency

- [ ] Any variable read on one thread and written on another without a
      mutex or atomic? (Includes "just a bool".) `[BLOCKER]`
- [ ] Guarded members lacking `ABSL_GUARDED_BY`; helpers lacking
      `LOCKS_REQUIRED`? `[MAJOR]`
- [ ] Lock held while calling a callback, a virtual on a foreign object,
      I/O, or another component's method that may take a lock? `[BLOCKER]`
- [ ] Two mutexes acquired in different orders anywhere? `[BLOCKER]`
- [ ] Condition variable waited without a predicate loop, or notified
      without the mutex held during the predicate write? `[BLOCKER]`
- [ ] Two atomics that must agree (size + data, flag + payload) with no
      release/acquire pairing? `[BLOCKER]`
- [ ] Non-default memory ordering without a comment justifying it?
      `[MAJOR]`
- [ ] Per-thread counters or state adjacent in memory (false sharing)?
      `[MAJOR on hot path]`
- [ ] Thread/pool declared before the members its tasks use (destruction
      order), or no join/stop in the destructor? `[BLOCKER]`
- [ ] `detach()`, `std::async` result discarded, `sleep` as
      synchronization? `[BLOCKER]`
- [ ] `shared_ptr` object mutated concurrently (only the control block is
      thread-safe)? `[BLOCKER]`
- [ ] Thread-safety of the class not stated in its comment? `[MINOR]`
- [ ] Concurrency test present and run under TSan? `[MAJOR if absent]`

## 5. API design and readability

- [ ] Call sites need a comment to understand argument meaning (`bool`
      params, adjacent same-type params)? `[MINOR]`
- [ ] Out-parameters where a return value or struct would do? `[MINOR]`
- [ ] `const std::string&` where `string_view` fits; `const
      std::vector<T>&` where `Span<const T>` fits? `[MINOR]`
- [ ] Non-`explicit` single-arg constructor? `[MAJOR]`
- [ ] Missing `const` on methods that don't mutate; missing
      `[[nodiscard]]` on results that matter? `[MINOR]`
- [ ] Two-phase init (`Init()`), or object constructible in an invalid
      state? `[MAJOR]`
- [ ] Overload set with different semantics; default arguments on virtual
      functions? `[MAJOR]`
- [ ] Plain `enum` instead of `enum class`; magic numbers; sentinel values
      instead of `optional`? `[MINOR]`
- [ ] `using namespace`, using-declarations in headers, non-project
      macros, `#define` constants? `[MAJOR in headers, MINOR in .cc]`
- [ ] Naming off the project convention; misleading names; abbreviations
      only the author knows? `[NIT..MINOR]`
- [ ] Comments say what instead of why; public declaration without a
      contract comment (ownership, threading, errors)? `[MINOR]`
- [ ] Function longer than a screen doing several things? `[MINOR]`
- [ ] Copy-pasted logic that should be one function? `[MINOR]`
- [ ] Includes missing (relies on transitive) or unused? `[NIT]`
- [ ] Inheritance for code reuse; deep hierarchy; god class? `[MAJOR]`
- [ ] Singleton or global mutable state introduced? `[MAJOR]`

## 6. Performance (hot paths only)

First decide: is it per element / per row / per request / per packet? If
not, skip this section except for gross issues.

- [ ] Allocation inside the loop (`std::string` construction, vector
      without reserve, `std::function`, `shared_ptr`, temporaries returned
      by value per element)? `[MAJOR]`
- [ ] Virtual/indirect/`std::function` call per element that could be
      hoisted per batch? `[MAJOR]`
- [ ] `std::map`/`std::set`/`std::unordered_map`/`std::list` on the hot
      path? `[MAJOR]`
- [ ] `auto x = ...` copying where `const auto&` was meant; range-for by
      value over non-trivial types; pass-by-value of large objects?
      `[MAJOR]`
- [ ] `shared_ptr` copied per element or per call? `[MAJOR]`
- [ ] String building with `+`, `stringstream`, `to_string` per element?
      `[MAJOR]`
- [ ] Unpredictable data-dependent branch in the inner loop that could be
      branchless or hoisted? `[MINOR unless measured]`
- [ ] Loop won't vectorize (aliasing through members, calls, mixed
      signedness) where it clearly could? `[MINOR]`
- [ ] Array-of-structs scanned for one field; pointer-chasing structure
      where a flat array works? `[MAJOR]`
- [ ] Lock or atomic RMW in the inner loop? `[MAJOR]`
- [ ] Division/modulo by a non-constant per element? `[MINOR]`
- [ ] Exception used for an expected outcome on the hot path? `[MAJOR]`
- [ ] Repeated work that could be computed once (regex compile, hash of
      the same key, `size()` of a list, lookup inside a loop invariant)?
      `[MINOR]`
- [ ] `dynamic_cast`/RTTI per element? `[MAJOR]`
- [ ] Performance claim without a benchmark, or benchmark that doesn't
      cover realistic sizes/distributions? `[MAJOR]`
- [ ] Benchmark not checked in for a new hot path? `[MINOR]`

## 7. Tests

- [ ] New behavior without a test named for it? `[MAJOR]`
- [ ] Bug fix without a regression test that fails before the fix?
      `[MAJOR]`
- [ ] Edge cases absent: empty, one, boundary sizes, max values, invalid
      input, each error path? `[MINOR..MAJOR]`
- [ ] Test asserts implementation details (call order on mocks, private
      state) rather than the contract? `[MINOR]`
- [ ] Test has logic (loops hiding which case fails, conditionals)?
      `[MINOR]`
- [ ] Test depends on timing, sleeps, real clock, network, or order of
      other tests? `[MAJOR]`
- [ ] Assertions use `EXPECT_TRUE(a == b)` instead of `EXPECT_EQ`/matchers
      (poor failure messages)? `[NIT]`
- [ ] Concurrency code without a stress test run under TSan? `[MAJOR]`
- [ ] Parser/decoder without a fuzz target? `[MINOR..MAJOR]`
- [ ] Test would still pass if the change were reverted? `[BLOCKER]`

## 8. Build, dependencies, hygiene

- [ ] New warnings (would fail `-Werror`)? Suppressed warnings without a
      justification comment? `[MAJOR]`
- [ ] `NOLINT` without a reason? `[MINOR]`
- [ ] Heavy header included in a widely used header (compile-time cost)?
      `[MINOR]`
- [ ] New third-party dependency without justification, pinning, and
      license check? `[MAJOR]`
- [ ] Dependency direction violated (low-level module includes
      high-level)? `[MAJOR]`
- [ ] Dead code, commented-out code, `#if 0`, stale TODOs? `[NIT]`
- [ ] Public API surface grown without need (could be in the `.cc`, an
      unnamed namespace, or private)? `[MINOR]`
- [ ] Formatting not from the formatter? `[NIT]`
- [ ] Commit message doesn't say why; performance claims without numbers?
      `[MINOR]`

## 9. Security-sensitive code

For parsers, network handlers, anything touching untrusted bytes:

- [ ] Length fields trusted before validation against the buffer?
      `[BLOCKER]`
- [ ] Integer overflow in size computations before allocation
      (`count * elem_size`)? `[BLOCKER]`
- [ ] Recursion or nesting without a depth limit? `[BLOCKER]`
- [ ] Total allocation unbounded by input size limits? `[MAJOR]`
- [ ] Format string, SQL, shell command, or path built from input?
      `[BLOCKER]`
- [ ] Secrets logged, kept in memory longer than needed, compared with
      non-constant-time comparison? `[MAJOR]`
- [ ] `strcpy`/`sprintf`/`gets`/`strcat`/`scanf("%s")`? `[BLOCKER]`
- [ ] Error messages leaking internal paths or data to remote callers?
      `[MINOR]`
- [ ] Fuzz target absent? `[MAJOR]`
