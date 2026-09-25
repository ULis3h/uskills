# Safety tooling: flags, sanitizers, hardening, fuzzing

Copy-paste-ready configuration. The CMake wiring for all of this lives in
`cpp-project-setup` (`assets/cmake/Warnings.cmake`,
`assets/cmake/Sanitizers.cmake`); this file explains what each piece does
and how to run it.

Contents:

1. [Warnings](#warnings)
2. [Sanitizers](#sanitizers)
3. [Hardened standard library and runtime checks](#hardened-standard-library)
4. [clang-tidy](#clang-tidy)
5. [Fuzzing with libFuzzer](#fuzzing-with-libfuzzer)
6. [CI matrix](#ci-matrix)

## Warnings

Baseline for clang and gcc (add incrementally on a legacy codebase):

```
-Wall -Wextra -Wpedantic
-Wshadow                 # local hides member/outer variable
-Wconversion -Wsign-conversion   # narrowing and signedness
-Wold-style-cast
-Wnon-virtual-dtor -Woverloaded-virtual
-Wnull-dereference
-Wimplicit-fallthrough
-Wformat=2
-Wcast-align -Wcast-qual
-Wdouble-promotion
-Wunused
-Wmisleading-indentation
-Wduplicated-cond -Wduplicated-branches -Wlogical-op   # gcc
-Wuseless-cast                                          # gcc
-Wextra-semi -Wcomma -Wdangling                         # clang
-Wthread-safety                                         # clang, with absl annotations
-Werror                  # in CI; locally optional
```

Enable `-Werror` per target in CI; do not rely on developers noticing
yellow text. Never fix a warning with a cast that hides the problem
(`static_cast<int>(size)` without a range check is worse than the warning).

## Sanitizers

Build separate configurations; sanitizers don't combine arbitrarily
(ASan+UBSan yes; TSan alone; MSan alone).

```bash
# AddressSanitizer + UndefinedBehaviorSanitizer (the default test build)
-fsanitize=address,undefined -fno-sanitize-recover=all
-fsanitize=float-divide-by-zero,implicit-conversion,local-bounds,nullability
-fno-omit-frame-pointer -O1 -g
export ASAN_OPTIONS=detect_stack_use_after_return=1:check_initialization_order=1:\
strict_init_order=1:detect_odr_violation=2:strict_string_checks=1:\
detect_leaks=1:abort_on_error=1:halt_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1:abort_on_error=1

# ThreadSanitizer
-fsanitize=thread -fno-omit-frame-pointer -O1 -g
export TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1:report_atomic_races=1

# MemorySanitizer (clang only, needs libc++ built with MSan; find uninitialized reads)
-fsanitize=memory -fsanitize-memory-track-origins=2 -fno-omit-frame-pointer -O1 -g
-stdlib=libc++ -L<msan-libcxx>/lib -Wl,-rpath,<msan-libcxx>/lib
export MSAN_OPTIONS=halt_on_error=1:print_stats=1
```

Notes:

- `-O1` or `-O2` with sanitizers keeps tests fast enough; `-O0` hides
  optimizer-dependent UB, `-O3` makes reports harder to read.
- `-fno-sanitize-recover=all` makes the first UB report fatal so CI is red.
- UBSan's `implicit-conversion` group (`implicit-integer-truncation`,
  `implicit-integer-sign-change`) is noisy on legacy code; enable it for
  new modules first.
- Suppress a known third-party issue with a suppression file
  (`ASAN_OPTIONS=suppressions=asan.supp`), never by disabling the check.
- TSan needs *all* code instrumented, including static libraries; an
  uninstrumented library produces false negatives, not false positives.
- Run sanitized tests with a timeout multiplier (ASan 2x, TSan 5-15x, MSan
  3x).
- `-fsanitize=cfi -flto -fvisibility=hidden` (clang) for production
  control-flow integrity; `-fsanitize=safe-stack` on hardened targets.

## Hardened standard library

Cheap runtime checks on container preconditions. Turn them on in test and
debug builds, and consider the fast mode in production (ClickHouse and
Google run with checks in production; the cost is a few percent):

```
# libc++ (clang) - choose one:
-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST      # bounds on [] and views; production-safe
-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE # + more preconditions
-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG     # + iterator validity; tests only

# libstdc++ (gcc)
-D_GLIBCXX_ASSERTIONS       # bounds and preconditions; production-viable
-D_GLIBCXX_DEBUG            # checked iterators (ABI-changing! whole program only)

# Abseil
-DABSL_HARDENED=1           # bounds checks in absl::Span, StatusOr, optional, InlinedVector...

# glibc / compiler hardening (release builds)
-D_FORTIFY_SOURCE=3 -O2     # checked memcpy/sprintf/... when sizes are known
-fstack-protector-strong
-fstack-clash-protection
-fcf-protection=full        # x86 CET
-ftrivial-auto-var-init=zero   # no uninitialized stack garbage (clang, gcc 12+)
-Wl,-z,relro,-z,now,-z,noexecstack
-fPIE -pie
```

## clang-tidy

Use the `.clang-tidy` from `cpp-project-setup/assets/.clang-tidy`. The
safety-relevant check groups and why:

- `bugprone-*`: use-after-move, dangling handles, narrowing, infinite
  loops, suspicious `memset`/`string` ops, integer division in float
  context, `sizeof` misuse, unchecked optional access.
- `cert-*`: CERT C++ rules (`cert-err34-c` on `atoi`, `cert-oop54-cpp`
  self-assignment, `cert-msc50` `rand`).
- `cppcoreguidelines-*`: `owning-memory`, `pro-type-*` casts,
  `slicing`, `init-variables`, `narrowing-conversions`, `special-member-
  functions`, `virtual-class-destructor`. Some (`pro-bounds-pointer-
  arithmetic`, `avoid-magic-numbers`) are too noisy for most codebases;
  disable deliberately.
- `misc-*`: `unconventional-assign-operator`, `misc-const-correctness`,
  `misc-unused-*`.
- `concurrency-*`: `mt-unsafe` (calls to non-thread-safe libc functions).
- `performance-*` (not safety, but cheap): `unnecessary-copy-initialization`,
  `for-range-copy`, `move-const-arg`, `inefficient-vector-operation`.

Run on the diff in CI (`clang-tidy-diff.py`) so legacy files don't block,
and on the whole tree nightly. Fix, don't `NOLINT`, unless a comment
explains the false positive.

## Fuzzing with libFuzzer

Every function that consumes bytes it doesn't produce (parsers, decoders,
protocol handlers, format converters, query parsers) gets a fuzz target.
ClickHouse runs fuzzers continuously on its SQL parser, its AST
transformations, and its input formats; they find bugs every week.

```cpp
// fuzz/parse_config_fuzzer.cc
#include <cstddef>
#include <cstdint>
#include <string_view>
#include "myproj/config.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::string_view input(reinterpret_cast<const char*>(data), size);
  auto result = myproj::ParseConfig(input);    // must not crash, hang, leak, or UB
  if (result.ok()) {
    // Round-trip property: serialize -> parse must succeed and be equal.
    auto again = myproj::ParseConfig(myproj::Serialize(*result));
    if (!again.ok() || *again != *result) __builtin_trap();
  }
  return 0;
}
```

```bash
clang++ -g -O1 -fsanitize=fuzzer,address,undefined parse_config_fuzzer.cc -o fuzzer ...
mkdir -p corpus && cp testdata/*.cfg corpus/
./fuzzer corpus -max_len=4096 -timeout=10 -rss_limit_mb=2048 -jobs=8 -workers=8
./fuzzer -minimize_crash=1 crash-xxxx     # shrink a crash input
./fuzzer -runs=0 corpus                   # regression: run the corpus once in CI
```

Guidelines:

- Seed the corpus with real inputs; coverage guidance builds from there.
- Add a `-dict=` file with keywords/tokens for grammar-heavy inputs.
- Fuzz *properties*, not just "doesn't crash": round trips, idempotence,
  equivalence with a reference implementation, invariants after mutation.
- Check found crashes in as regression tests (`testdata/crashes/*`), run
  them under sanitizers in the normal test suite.
- Structured fuzzing (libprotobuf-mutator, FuzzedDataProvider) when the
  input is a struct rather than bytes.
- Integrate with OSS-Fuzz or run in CI with a time budget per target.

## CI matrix

Minimum for a project that takes safety seriously:

| Job | Config | Purpose |
|---|---|---|
| debug | `-O0 -g`, hardened stdlib debug mode, `DCHECK` on | assertions, iterator checks |
| release | `-O2`, `-Werror`, hardened fast mode | what ships |
| asan+ubsan | clang, all tests | memory and UB |
| tsan | clang, concurrency tests at minimum | races, deadlocks |
| msan | clang + MSan libc++, nightly | uninitialized reads |
| clang-tidy | on the diff | static bugs |
| fuzz regression | `-runs=0` on corpus + crashes | no regressions |
| fuzz nightly | 1-4 CPU-hours per target | new bugs |
| gcc build | latest gcc, `-Werror` | portability, different warnings |
