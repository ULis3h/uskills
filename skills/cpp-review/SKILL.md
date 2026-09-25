---
name: cpp-review
description: Review C++ code (a diff, a pull request, a file, or a whole module) for correctness and undefined behavior, ownership and lifetime bugs, API and style problems in the Abseil sense, performance regressions on hot paths in the ClickHouse sense, concurrency hazards, and missing tests, and report findings ordered by severity with concrete fixes. Use this skill whenever the user asks to review, audit, critique, check, or "look over" C++ code, asks "is this correct/safe/fast/idiomatic", requests a code review of a PR touching .cc/.h files, or asks what could go wrong with a C++ change. Also use it before submitting your own C++ changes as a self-review pass.
---

# C++ code review

A review is a search for the bugs that tests will not catch and the costs
that will not show until production. Work through the lenses in order;
correctness bugs outrank style, and a performance finding on a cold path
is a nit. Every finding names the file and line, states the concrete
failure (input → wrong behavior), and proposes the fix.

The full checklist is in `references/checklist.md`; read it for any
non-trivial review. The domain skills (`cpp-style`, `cpp-safety`,
`cpp-performance`, `cpp-concurrency`, `cpp-design-patterns`) hold the
reasoning behind each item; consult them when a finding needs
justification or when the reviewed code is unusual.

## Procedure

1. **Understand the change.** Read the description, then the diff, then
   the surrounding code the diff calls or is called by. A review of the
   diff alone misses invalidated assumptions in callers.
2. **Lens 1: correctness and UB.** Walk every pointer, reference, view,
   index, cast, and arithmetic expression. Ask for each: can it be
   null/empty/dangling/out of range/overflowed? Check moved-from use,
   iterator invalidation, error paths that skip cleanup, unchecked
   `Status`/return codes, exhaustive switches, off-by-one at boundaries,
   integer widths and signedness.
3. **Lens 2: ownership and lifetime.** For each stored pointer, reference,
   `string_view`, `Span`, lambda capture, callback registration: who owns
   it, what guarantees the owner outlives the holder, is that written down.
4. **Lens 3: concurrency.** Any shared mutable state? Which lock, is it
   annotated, is it held across callbacks, is the lock order consistent,
   are atomics used for single variables only, is shutdown/join ordered.
5. **Lens 4: API and readability (Abseil).** Call sites read clearly?
   Parameter types per the `cpp-style` table? Errors as `Status`? Explicit
   constructors, `[[nodiscard]]`, `const`, `enum class`, option structs
   instead of bools, naming, comments explaining why, no
   `using namespace`, includes complete.
6. **Lens 5: performance (ClickHouse), only where hot.** Decide if the
   code is on a per-element/per-request path. If so: allocation in loops,
   virtual/indirect calls per element, `std::map`/`unordered_map`/`list`,
   `shared_ptr` copies, string building, unnecessary copies (`auto` instead
   of `const auto&`, pass-by-value of large types), unpredictable branches,
   data layout, missing `reserve`. Ask for the benchmark if the change
   claims a speedup or touches a known hot path.
7. **Lens 6: tests.** Is the new behavior tested by name? Edge cases:
   empty, one element, max size, invalid input, error propagation,
   concurrency (under TSan)? Do tests assert the contract rather than
   implementation details? Would the test fail if the fix were reverted?
8. **Lens 7: build and hygiene.** Warnings, formatting, dead code, TODOs
   with owners, header guards, dependency direction, public API surface
   growth.
9. **Write the report.**

## Report format

```
## Summary
One paragraph: what the change does, overall verdict (ready / needs changes / needs design discussion), the one or two most important findings.

## Findings
Ordered by severity. Each:
**[BLOCKER|MAJOR|MINOR|NIT] file.cc:123 — short title**
What is wrong, the concrete failure scenario, and the fix (with a code snippet when it is not obvious).

## Questions
Things you could not determine from the code (intended lifetime, expected input sizes, whether the path is hot).

## Praise (optional, brief)
Something genuinely well done that should be kept.
```

Severity:

- **BLOCKER**: UB, memory/lifetime bug, data race, security issue, wrong
  result, silent error swallowing, a test that cannot fail.
- **MAJOR**: API that will be misused, missing error handling on a real
  failure mode, performance regression on a hot path, missing test for
  the main behavior, thread-safety not documented for shared code.
- **MINOR**: style deviations with a reader cost, suboptimal but correct
  code on a warm path, missing edge-case test.
- **NIT**: naming, formatting the tool didn't catch, comment wording.

Be specific and verifiable; "this might be slow" is not a finding,
"`ProcessRow` allocates a `std::string` per row (line 88) and is called
for every row in `Scan`; hoist the buffer or use `string_view`" is. Do not
pad the report with generic advice. If the code is good, say so briefly.

## Self-review before submitting your own change

Run the same lenses over your own diff, then additionally:

- Build with warnings as errors and run clang-tidy on the changed files.
- Run the tests under ASan/UBSan (and TSan if threads are involved).
- Re-read the diff top to bottom asking "what input breaks this?".
- Confirm the commit message says what and why, and includes benchmark
  numbers for any performance claim.
