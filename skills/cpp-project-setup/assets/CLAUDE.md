# CLAUDE.md

<!-- Template from the `cpp` skills plugin (cpp-project-setup). Copy to the
     repository root and edit the project-specific sections. Keep it short:
     this file is in context for every turn; depth lives in the skills. -->

## Project

<!-- One paragraph: what this codebase is, the main directories, how modules
     depend on each other. -->

## Build and test

```bash
cmake --preset dev                 # configure (clang, RelWithDebInfo, hardened)
cmake --build --preset dev         # build with -Werror
ctest --preset dev                 # run tests
cmake --preset asan && cmake --build --preset asan && ctest --preset asan   # sanitizers
cmake --build --preset dev --target format   # clang-format everything
cmake --build --preset dev --target tidy     # clang-tidy everything
```

## Definition of done

A change is finished only when all of these hold. Do not report completion
before checking each one; the Stop hook enforces the first three.

1. `cmake --build --preset dev` succeeds with zero warnings.
2. `ctest --preset dev` passes, including a test named after every new
   behavior and a regression test for every bug fixed.
3. The changed files are clang-format clean and clang-tidy clean (the
   PostToolUse hook runs both; fix findings, do not `NOLINT` them).
4. For anything that touches pointers, indices, or threads: tests pass under
   the `asan` preset (and `tsan` for threaded code).
5. For anything on a hot path: a benchmark exists and the commit message
   carries before/after numbers.

## C++ rules that apply to every line

These are the always-on subset of the `cpp-style`, `cpp-safety`, and
`cpp-performance` skills. Load those skills for the reasoning and the
details; the exemplar module in `cpp-style/references/exemplar.md` shows
the target shape of a header, an implementation, and a test.

- Write for the reader at the call site. If a call needs a comment to be
  understood, change the signature (option struct, enum instead of bool,
  designated initializers).
- Ownership lives in the type: `std::unique_ptr` owns; `T*`/`T&` borrow;
  `std::shared_ptr` needs a comment saying who shares. No raw `new`/`delete`.
- Errors are values: `absl::Status` / `absl::StatusOr<T>`; check every one.
  Preconditions are `CHECK`/`DCHECK`, not statuses. No sentinels, no
  swallowed failures.
- Parameters: `absl::string_view` / `absl::Span<const T>` to read,
  `const T&` for large read-only objects, by value + `std::move` to store,
  `absl::FunctionRef` for callbacks not kept. Return values, not
  out-parameters.
- Never store a `string_view`, `Span`, reference, or `[&]` lambda beyond
  the lifetime of its source; if it must be stored, write the lifetime
  guarantee in the class comment.
- `explicit` constructors, `enum class`, exhaustive `switch` without
  `default`, `[[nodiscard]]` on results that matter, `const` everywhere it
  can be, default member initializers on every member.
- Fallible construction goes through `static absl::StatusOr<T> Create(...)`;
  no `Init()` methods.
- Every public declaration has a comment stating contract, errors,
  ownership, and thread-safety. Comments explain why, not what.
- Shared mutable state is `ABSL_GUARDED_BY` a named mutex; critical
  sections are short and call no unknown code. Unsynchronized sharing is
  UB, even for a `bool`.
- On a hot path (per element, per row, per request): no allocation, no
  virtual or `std::function` call, no lock, no `std::map`/`unordered_map`/
  `list`, no `shared_ptr` copy, no exception, no string building inside the
  loop. Dispatch once per batch, then a tight loop over contiguous memory.
- Any performance claim comes with a benchmark and numbers.
- Tests: one behavior per test, named `Thing, BehaviorWhenCondition`;
  GoogleTest matchers; no logic in tests; fakes over mocks; edge cases
  (empty, one, boundary, invalid input, each error path).

## Layout and naming

- `src/<project>/<module>/` holds `foo.h`, `foo.cc`, `foo_test.cc`,
  `foo_bench.cc` side by side. Include as `"<project>/<module>/foo.h"`.
- Google naming: `PascalCase` types and functions, `snake_case` variables,
  `member_` data members, `kConstant`, `MACRO_NAME`.
- Formatting is clang-format's job; never hand-align.

## Things to ask before doing

- Adding a third-party dependency.
- Changing a public API used outside this repository.
- Anything that needs `-fno-strict-aliasing`, `reinterpret_cast`,
  `const_cast`, a `NOLINT`, or a sanitizer suppression.
