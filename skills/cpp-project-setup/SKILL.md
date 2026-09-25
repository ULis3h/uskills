---
name: cpp-project-setup
description: Set up or modernize a C++ project's build and tooling: CMake (presets, targets, warnings, sanitizer configs, LTO, ccache, Ninja), clang-format in Google style, clang-tidy, dependency management for Abseil/GoogleTest/Google Benchmark/fmt, directory layout, CI matrix. Use this skill whenever the user starts a new C++ project or library, asks for a CMakeLists.txt, CMakePresets, .clang-format, .clang-tidy, compiler flags, "how to enable sanitizers", how to add Abseil/gtest/benchmark, or when an existing C++ repo lacks warnings, formatting, static analysis, or test/bench targets. Also use it when a build is slow or flaky and the fix is build-system hygiene.
---

# C++ project setup

A project that compiles with every warning on, formats itself, runs its
tests under sanitizers, and benchmarks its hot paths is the precondition
for everything in the other `cpp-*` skills. This skill gives a complete,
copyable baseline. Copy the files from `assets/` into the project and adapt
names; do not hand-type them from memory.

Assets:

| File | Purpose |
|---|---|
| `assets/CMakeLists.txt` | Top-level template: standards, options, dependencies, targets, tests, benchmarks |
| `assets/CMakePresets.json` | `dev`, `release`, `asan`, `tsan`, `msan`, `coverage` presets with Ninja + ccache |
| `assets/cmake/Warnings.cmake` | `project_warnings` interface target (clang/gcc/msvc) |
| `assets/cmake/Sanitizers.cmake` | `SANITIZER=address,undefined|thread|memory` option handling |
| `assets/cmake/Hardening.cmake` | hardened stdlib, fortify, stack protector, CFI flags |
| `assets/.clang-format` | Google style, 100 columns, C++20 |
| `assets/.clang-tidy` | Curated checks with rationale |
| `assets/.editorconfig` | Line endings, indentation |
| `assets/.gitignore` | Build dirs, caches |
| `assets/ci.yml` | GitHub Actions matrix: gcc/clang × debug/release/asan/tsan, clang-tidy on diff, format check |
| `assets/CLAUDE.md` | Always-in-context project rules: build commands, definition of done, the core C++ rules |
| `assets/tools/claude/claude-settings.json` | Claude Code hooks wiring (copy to `.claude/settings.json`) |
| `assets/tools/claude/post_edit_cpp.sh` | PostToolUse hook: clang-format the edited file, clang-tidy it, return findings to Claude |
| `assets/tools/claude/stop_check_cpp.sh` | Stop hook: refuse to finish while changed C++ doesn't build warning-free and pass tests |

## 0. Making the rules enforced, not advisory

Skills are text; they raise the default quality of what Claude writes but
cannot by themselves guarantee that the code compiles, passes clang-tidy,
or passes tests. Three additions close that gap, and they are the highest
value part of this setup:

1. **`CLAUDE.md`** at the repository root (from `assets/CLAUDE.md`) keeps
   the build commands, the definition of done, and the ~15 always-on C++
   rules in context every turn. Skills load only when triggered; this
   doesn't.
2. **PostToolUse hook** (`post_edit_cpp.sh`): after every edit of a C++
   file, format it and run clang-tidy against the `dev` compile database.
   Findings come back as blocking feedback, so Claude fixes them
   immediately instead of after review.
3. **Stop hook** (`stop_check_cpp.sh`): when Claude tries to finish with
   modified C++ files, build with `-Werror` and run the tests. Failure
   output is returned and the turn continues. `stop_hook_active` prevents
   loops; `CPP_HOOKS=0` disables both hooks for a session.

Install:

```bash
mkdir -p tools/claude .claude
cp <skill>/assets/tools/claude/*.sh tools/claude/ && chmod +x tools/claude/*.sh
cp <skill>/assets/tools/claude/claude-settings.json .claude/settings.json   # or merge
cp <skill>/assets/CLAUDE.md CLAUDE.md   # then fill in the Project section
cmake --preset dev                      # creates the compile database the hooks use
```

Use a separate reviewer for real review: run `cpp-review` in a fresh
session or subagent on the diff, so the author's context doesn't bias it.

## 1. Layout

```
project/
├── CMakeLists.txt          # top level; add_subdirectory for each module
├── CMakePresets.json
├── cmake/                  # Warnings.cmake, Sanitizers.cmake, Hardening.cmake, deps
├── src/project/            # public headers next to sources: src/project/net/connection.h + .cc
│   └── net/
│       ├── connection.h
│       ├── connection.cc
│       ├── connection_test.cc
│       └── connection_bench.cc
├── third_party/            # vendored or FetchContent'd deps (never edited)
├── tools/                  # scripts: format.sh, tidy.sh, run_fuzzers.sh
├── fuzz/                   # libFuzzer targets
├── .clang-format  .clang-tidy  .editorconfig  .gitignore
└── .github/workflows/ci.yml
```

- Headers live next to their sources under a project-named directory so
  includes are `#include "project/net/connection.h"` and never ambiguous.
  A separate `include/` tree is only needed for an installed library with
  a strictly public subset.
- Tests and benchmarks sit beside the code they test (`_test.cc`,
  `_bench.cc`); CMake globs them into `project_tests` and `project_benches`.
- One CMake target per library module (`project_net`), with `PUBLIC`
  dependencies declared so consumers get transitive includes.

## 2. Compiler and standard

- Clang preferred (better diagnostics, sanitizers, `-ftime-trace`,
  thread-safety analysis); build with gcc too in CI for portability.
- `CMAKE_CXX_STANDARD 20`, `CMAKE_CXX_STANDARD_REQUIRED ON`,
  `CMAKE_CXX_EXTENSIONS OFF`. Use C++23 if the toolchain baseline allows
  (deducing `this`, `std::expected`, `std::print`).
- `CMAKE_EXPORT_COMPILE_COMMANDS ON` always (clang-tidy, IDEs).
- `-fno-omit-frame-pointer` in every config: profiles must be readable.
- Release: `-O2` or `-O3`, `-DNDEBUG` only if the project's `DCHECK`s are
  meant to go away; keep `CHECK`s on. LTO (`CMAKE_INTERPROCEDURAL_OPTIMIZATION`)
  for shipped binaries. `-march` never baked in for distributed binaries;
  runtime dispatch instead (see `cpp-performance/references/vectorization.md`).
- Position-independent code and hidden visibility by default
  (`CMAKE_POSITION_INDEPENDENT_CODE ON`, `CMAKE_CXX_VISIBILITY_PRESET
  hidden`).
- ccache via `CMAKE_CXX_COMPILER_LAUNCHER`, Ninja generator, `mold` or
  `lld` linker (`-fuse-ld=lld`).

## 3. Dependencies

Prefer, in order: the system/package manager the project already uses
(vcpkg, Conan, Bazel modules); `FetchContent` with pinned tags for a small
number of source deps; vendored `third_party/` for things that must be
patched. Baseline set:

| Library | Why | Note |
|---|---|---|
| Abseil (`abseil-cpp`) | `Status`, `StatusOr`, strings, hash containers, `Mutex`, time | `ABSL_PROPAGATE_CXX_STD ON`; build once with the same standard as the project |
| GoogleTest | tests, matchers, `gmock` | `gtest_discover_tests` |
| Google Benchmark | microbenchmarks | `BENCHMARK_ENABLE_TESTING OFF` |
| fmt | formatting when Abseil `StrFormat` is not enough (`fmt::format_to` into buffers) | or `std::format` on new toolchains |
| jemalloc / mimalloc | production allocator | link into the final binary only |
| xxHash / CityHash | fast hashing | only if `absl::Hash` isn't enough |

Pin versions with a commit hash or tag; never `GIT_TAG main`.

## 4. Targets

- `project_warnings`: interface library carrying the warning flags; every
  target links it `PRIVATE`. Third-party targets don't.
- `project_options`: interface library carrying standard, sanitizer, and
  hardening flags.
- Libraries: `add_library(project_net STATIC ...)`; `target_link_libraries(
  project_net PUBLIC absl::status absl::strings PRIVATE project_warnings
  project_options)`.
- Tests: one executable per module or one for the project; `gtest_main`,
  `gtest_discover_tests(project_tests DISCOVERY_MODE PRE_TEST)`.
- Benchmarks: `add_executable(project_benches ...)` linking
  `benchmark::benchmark_main`; not part of `ctest` by default; a
  `bench` custom target runs them.
- Fuzzers: built only when `PROJECT_FUZZ=ON` with clang; each target links
  `-fsanitize=fuzzer`.
- `format` / `format-check` custom targets running `clang-format`;
  `tidy` running `run-clang-tidy` on `compile_commands.json`.

## 5. Quality gates in CI

| Job | Preset | Gate |
|---|---|---|
| format-check | n/a | `clang-format --dry-run --Werror` on changed files |
| clang-tidy | `dev` | `clang-tidy-diff` on the PR diff, warnings as errors |
| build+test gcc | `release` | all tests, `-Werror` |
| build+test clang | `release` | all tests, `-Werror` |
| asan+ubsan | `asan` | all tests |
| tsan | `tsan` | all tests (or the concurrency subset) |
| msan (nightly) | `msan` | all tests |
| bench (nightly or on label) | `release` | compare against `main`, fail on > 5% regression on tracked benches |
| fuzz regression | `asan` | run corpus, `-runs=0` |

## 6. Workflow for a new project

1. Copy `assets/*` into the repository root and `cmake/`; rename
   `project` to the real name in `CMakeLists.txt`, presets, and
   `.clang-tidy` (namespace and header guard patterns).
2. `cmake --preset dev && cmake --build --preset dev && ctest --preset dev`.
   Fix any warning immediately; the baseline must be clean.
3. Add the first module with a `_test.cc` and a `_bench.cc` so the targets
   are exercised from day one.
4. Commit the CI workflow; make the sanitizer jobs required for merge.
5. For an existing project: add `project_warnings` with a subset of flags,
   grow it module by module; enable `-Werror` per target as each becomes
   clean; introduce clang-tidy on the diff first.
