# Exemplar: a complete Abseil-style module

One realistic module, written the way this skill asks: header, implementation,
and test. Imitate its shape. Notes after each file point at the decisions
that matter. The module is a token-bucket rate limiter with an injected
clock; it is small enough to read in a few minutes and exercises most of
the rules in `SKILL.md`.

Contents:

1. [`rate_limiter.h`](#rate_limiterh)
2. [`rate_limiter.cc`](#rate_limitercc)
3. [`rate_limiter_test.cc`](#rate_limiter_testcc)
4. [`BUILD` / CMake](#build)
5. [What to copy from this](#what-to-copy-from-this)

## `rate_limiter.h`

```cpp
// Copyright 2026 The Project Authors. Licensed under the Apache License 2.0.

#ifndef MYPROJ_UTIL_RATE_LIMITER_H_
#define MYPROJ_UTIL_RATE_LIMITER_H_

#include <memory>

#include "absl/base/thread_annotations.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/time.h"

namespace myproj::util {

// A source of the current time. Injected into RateLimiter so tests can
// control time deterministically.
//
// Implementations must be thread-safe.
class Clock {
 public:
  virtual ~Clock() = default;
  virtual absl::Time Now() const = 0;
};

// Returns the process-wide clock backed by absl::Now(). The returned object
// lives for the life of the process.
const Clock& SystemClock();

struct RateLimiterOptions {
  // Sustained rate at which tokens are replenished. Must be positive and
  // finite.
  double tokens_per_second = 100.0;

  // Maximum number of tokens the bucket holds, i.e. the largest burst that
  // can be admitted at once. Must be positive and finite.
  double burst = 100.0;

  // If true, the bucket starts full; otherwise it starts empty.
  bool start_full = true;
};

// A token-bucket rate limiter.
//
// Tokens accrue continuously at `tokens_per_second` up to `burst`. Callers
// take tokens with TryAcquire(); requests that cannot be satisfied now are
// rejected rather than queued, so callers decide whether to wait, retry, or
// shed load. TimeUntilAvailable() tells them how long a wait would be.
//
// Thread-safe.
//
// Example:
//
//   ASSIGN_OR_RETURN(std::unique_ptr<RateLimiter> limiter,
//                    RateLimiter::Create({.tokens_per_second = 50, .burst = 10}));
//   if (!limiter->TryAcquire()) {
//     return absl::ResourceExhaustedError("rate limit exceeded");
//   }
class RateLimiter {
 public:
  // Creates a limiter with the given options. Returns InvalidArgument if
  // `options.tokens_per_second` or `options.burst` is not positive and finite.
  //
  // `clock` must outlive the returned limiter.
  static absl::StatusOr<std::unique_ptr<RateLimiter>> Create(
      const RateLimiterOptions& options, const Clock& clock = SystemClock());

  RateLimiter(const RateLimiter&) = delete;
  RateLimiter& operator=(const RateLimiter&) = delete;

  // Takes `tokens` from the bucket and returns true if that many are
  // available; otherwise returns false and takes nothing.
  //
  // `tokens` must be positive. A request larger than `burst` can never be
  // satisfied and always returns false.
  bool TryAcquire(double tokens = 1.0) ABSL_LOCKS_EXCLUDED(mu_);

  // Returns how long a caller would have to wait before TryAcquire(tokens)
  // could succeed, assuming no other callers. Returns ZeroDuration() if it
  // would succeed now and InfiniteDuration() if `tokens` exceeds `burst`.
  //
  // `tokens` must be positive.
  absl::Duration TimeUntilAvailable(double tokens = 1.0) const
      ABSL_LOCKS_EXCLUDED(mu_);

  const RateLimiterOptions& options() const { return options_; }

 private:
  RateLimiter(const RateLimiterOptions& options, const Clock& clock);

  // Returns the token count as of `now`, given `last_refill_` and `tokens_`.
  double TokensAt(absl::Time now) const ABSL_SHARED_LOCKS_REQUIRED(mu_);

  const RateLimiterOptions options_;
  const Clock& clock_;

  mutable absl::Mutex mu_;
  double tokens_ ABSL_GUARDED_BY(mu_);
  absl::Time last_refill_ ABSL_GUARDED_BY(mu_);
};

}  // namespace myproj::util

#endif  // MYPROJ_UTIL_RATE_LIMITER_H_
```

Notes:

- The header is the documentation. Every public symbol states its contract,
  its failure modes, its lifetime requirements ("`clock` must outlive"), and
  its thread-safety, before any implementation detail.
- Fallible construction goes through a `static Create` returning
  `StatusOr<unique_ptr<...>>`; the constructor is private, so an invalid
  limiter cannot exist. The class is non-copyable because it holds a mutex
  and a reference.
- Configuration is an option struct with defaults and per-field comments,
  used with designated initializers at call sites.
- The dependency (`Clock`) is a tiny pure interface with a virtual
  destructor, injected by `const&` with a documented lifetime, defaulted to
  the production implementation so ordinary callers don't pay for
  testability.
- Every guarded member says which mutex guards it; every method says
  whether it takes or requires the lock, so `-Wthread-safety` checks the
  discipline.
- Doubles are used because the domain (fractional tokens over time) is
  continuous; the header says what happens at the edges (`burst`,
  non-positive input).

## `rate_limiter.cc`

```cpp
// Copyright 2026 The Project Authors. Licensed under the Apache License 2.0.

#include "myproj/util/rate_limiter.h"

#include <algorithm>
#include <cmath>
#include <memory>

#include "absl/base/no_destructor.h"
#include "absl/log/absl_check.h"
#include "absl/memory/memory.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_format.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"

namespace myproj::util {
namespace {

class SystemClockImpl final : public Clock {
 public:
  absl::Time Now() const override { return absl::Now(); }
};

absl::Status ValidatePositiveFinite(double value, absl::string_view name) {
  if (!(std::isfinite(value) && value > 0)) {
    return absl::InvalidArgumentError(
        absl::StrFormat("%s must be positive and finite, got %g", name, value));
  }
  return absl::OkStatus();
}

}  // namespace

const Clock& SystemClock() {
  static const absl::NoDestructor<SystemClockImpl> clock;
  return *clock;
}

absl::StatusOr<std::unique_ptr<RateLimiter>> RateLimiter::Create(
    const RateLimiterOptions& options, const Clock& clock) {
  if (absl::Status s =
          ValidatePositiveFinite(options.tokens_per_second, "tokens_per_second");
      !s.ok()) {
    return s;
  }
  if (absl::Status s = ValidatePositiveFinite(options.burst, "burst"); !s.ok()) {
    return s;
  }
  // The constructor is private, so make_unique cannot be used here.
  return absl::WrapUnique(new RateLimiter(options, clock));
}

RateLimiter::RateLimiter(const RateLimiterOptions& options, const Clock& clock)
    : options_(options),
      clock_(clock),
      tokens_(options.start_full ? options.burst : 0.0),
      last_refill_(clock.Now()) {}

double RateLimiter::TokensAt(absl::Time now) const {
  // Time can appear to go backwards with a non-monotonic clock; never
  // subtract tokens for that.
  const double elapsed_seconds =
      std::max(absl::ToDoubleSeconds(now - last_refill_), 0.0);
  return std::min(tokens_ + elapsed_seconds * options_.tokens_per_second,
                  options_.burst);
}

bool RateLimiter::TryAcquire(double tokens) {
  ABSL_DCHECK_GT(tokens, 0.0);
  if (tokens > options_.burst) return false;

  const absl::Time now = clock_.Now();
  absl::MutexLock lock(&mu_);
  const double available = TokensAt(now);
  if (available < tokens) return false;
  tokens_ = available - tokens;
  last_refill_ = std::max(now, last_refill_);
  return true;
}

absl::Duration RateLimiter::TimeUntilAvailable(double tokens) const {
  ABSL_DCHECK_GT(tokens, 0.0);
  if (tokens > options_.burst) return absl::InfiniteDuration();

  const absl::Time now = clock_.Now();
  absl::MutexLock lock(&mu_);
  const double deficit = tokens - TokensAt(now);
  if (deficit <= 0) return absl::ZeroDuration();
  return absl::Seconds(deficit / options_.tokens_per_second);
}

}  // namespace myproj::util
```

Notes:

- Includes: own header first, then standard, then third-party, each sorted;
  everything used is included directly (`absl/status/status.h` even though
  `statusor.h` happens to pull it in).
- File-local helpers live in an unnamed namespace, not as private static
  members, so the header never changes when the implementation does.
- The process-wide clock is a function-local `absl::NoDestructor` static:
  no static-initialization-order problems, no destructor at exit.
- Validation produces `InvalidArgument` with the offending value and field
  name in the message. The checks use `if (Status s = ...; !s.ok())` scoping
  instead of a pyramid.
- Precondition violations (`tokens <= 0`) are programmer errors, so they are
  `DCHECK`ed and documented, not turned into a `Status`.
- The critical section is short and calls nothing that could block or
  re-enter. The clock is read *outside* the lock. Edge cases (clock going
  backwards, request larger than burst) are handled explicitly and named in
  comments.
- No `new` except inside `absl::WrapUnique` for the private constructor; no
  `shared_ptr`; no output parameters; `const` on every local that is not
  reassigned.

## `rate_limiter_test.cc`

```cpp
// Copyright 2026 The Project Authors. Licensed under the Apache License 2.0.

#include "myproj/util/rate_limiter.h"

#include <cmath>
#include <memory>

#include "gmock/gmock.h"
#include "gtest/gtest.h"
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/time/time.h"

namespace myproj::util {
namespace {

using ::absl_testing::IsOk;
using ::absl_testing::StatusIs;
using ::testing::HasSubstr;

class FakeClock final : public Clock {
 public:
  absl::Time Now() const override { return now_; }
  void Advance(absl::Duration d) { now_ += d; }

 private:
  absl::Time now_ = absl::UnixEpoch();
};

class RateLimiterTest : public ::testing::Test {
 protected:
  // Creates a limiter that must be valid; the test fails otherwise.
  std::unique_ptr<RateLimiter> MakeLimiter(const RateLimiterOptions& options) {
    absl::StatusOr<std::unique_ptr<RateLimiter>> limiter =
        RateLimiter::Create(options, clock_);
    EXPECT_THAT(limiter, IsOk());
    return std::move(limiter).value_or(nullptr);
  }

  FakeClock clock_;
};

TEST_F(RateLimiterTest, CreateRejectsNonPositiveRate) {
  EXPECT_THAT(RateLimiter::Create({.tokens_per_second = 0}, clock_),
              StatusIs(absl::StatusCode::kInvalidArgument,
                       HasSubstr("tokens_per_second")));
  EXPECT_THAT(RateLimiter::Create({.tokens_per_second = -1}, clock_),
              StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST_F(RateLimiterTest, CreateRejectsNonFiniteBurst) {
  EXPECT_THAT(RateLimiter::Create({.burst = INFINITY}, clock_),
              StatusIs(absl::StatusCode::kInvalidArgument, HasSubstr("burst")));
  EXPECT_THAT(RateLimiter::Create({.burst = NAN}, clock_),
              StatusIs(absl::StatusCode::kInvalidArgument, HasSubstr("burst")));
}

TEST_F(RateLimiterTest, FullBucketAdmitsBurstThenRejects) {
  std::unique_ptr<RateLimiter> limiter =
      MakeLimiter({.tokens_per_second = 1, .burst = 3});
  ASSERT_NE(limiter, nullptr);

  EXPECT_TRUE(limiter->TryAcquire());
  EXPECT_TRUE(limiter->TryAcquire());
  EXPECT_TRUE(limiter->TryAcquire());
  EXPECT_FALSE(limiter->TryAcquire());
}

TEST_F(RateLimiterTest, EmptyBucketRefillsAtConfiguredRate) {
  std::unique_ptr<RateLimiter> limiter =
      MakeLimiter({.tokens_per_second = 2, .burst = 10, .start_full = false});
  ASSERT_NE(limiter, nullptr);

  EXPECT_FALSE(limiter->TryAcquire());
  EXPECT_EQ(limiter->TimeUntilAvailable(), absl::Milliseconds(500));

  clock_.Advance(absl::Milliseconds(499));
  EXPECT_FALSE(limiter->TryAcquire());

  clock_.Advance(absl::Milliseconds(1));
  EXPECT_TRUE(limiter->TryAcquire());
  EXPECT_FALSE(limiter->TryAcquire());
}

TEST_F(RateLimiterTest, RefillIsCappedAtBurst) {
  std::unique_ptr<RateLimiter> limiter =
      MakeLimiter({.tokens_per_second = 1000, .burst = 2});
  ASSERT_NE(limiter, nullptr);

  clock_.Advance(absl::Hours(1));
  EXPECT_TRUE(limiter->TryAcquire(2));
  EXPECT_FALSE(limiter->TryAcquire());
}

TEST_F(RateLimiterTest, RequestLargerThanBurstIsNeverAvailable) {
  std::unique_ptr<RateLimiter> limiter =
      MakeLimiter({.tokens_per_second = 1, .burst = 1});
  ASSERT_NE(limiter, nullptr);

  EXPECT_FALSE(limiter->TryAcquire(1.5));
  EXPECT_EQ(limiter->TimeUntilAvailable(1.5), absl::InfiniteDuration());
  // The failed request consumed nothing.
  EXPECT_TRUE(limiter->TryAcquire(1));
}

TEST_F(RateLimiterTest, ClockGoingBackwardsDoesNotRemoveTokens) {
  std::unique_ptr<RateLimiter> limiter =
      MakeLimiter({.tokens_per_second = 1, .burst = 5});
  ASSERT_NE(limiter, nullptr);

  clock_.Advance(-absl::Seconds(10));
  EXPECT_EQ(limiter->TimeUntilAvailable(5), absl::ZeroDuration());
  EXPECT_TRUE(limiter->TryAcquire(5));
}

}  // namespace
}  // namespace myproj::util
```

Notes:

- Test names read as sentences about behavior:
  `EmptyBucketRefillsAtConfiguredRate`, not `TestRefill`.
- Time is faked through the injected interface, so tests are deterministic
  and instant; no `sleep`.
- Matchers (`StatusIs`, `HasSubstr`, `IsOk`) give useful failure output
  and assert the error *code and message*, which is the contract.
- Each test checks one behavior and its edge (the 499 ms vs 500 ms
  boundary, the request that must consume nothing on failure, the
  backwards clock). No loops or conditionals in tests.
- The fixture holds only what every test needs (the clock) and a helper
  that turns a construction failure into a clear test failure.

## Build

Bazel:

```python
cc_library(
    name = "rate_limiter",
    srcs = ["rate_limiter.cc"],
    hdrs = ["rate_limiter.h"],
    deps = [
        "@abseil-cpp//absl/base:core_headers",
        "@abseil-cpp//absl/base:no_destructor",
        "@abseil-cpp//absl/log:absl_check",
        "@abseil-cpp//absl/memory",
        "@abseil-cpp//absl/status",
        "@abseil-cpp//absl/status:statusor",
        "@abseil-cpp//absl/strings:str_format",
        "@abseil-cpp//absl/synchronization",
        "@abseil-cpp//absl/time",
    ],
)

cc_test(
    name = "rate_limiter_test",
    srcs = ["rate_limiter_test.cc"],
    deps = [
        ":rate_limiter",
        "@abseil-cpp//absl/status",
        "@abseil-cpp//absl/status:status_matchers",
        "@abseil-cpp//absl/time",
        "@googletest//:gtest_main",
    ],
)
```

CMake (with the `cpp-project-setup` template):

```cmake
add_library(myproj_util_rate_limiter rate_limiter.cc rate_limiter.h)
target_link_libraries(myproj_util_rate_limiter
  PUBLIC absl::statusor absl::synchronization absl::time absl::core_headers
  PRIVATE absl::no_destructor absl::absl_check absl::memory absl::str_format
          project_warnings project_options)
# rate_limiter_test.cc is picked up by the project_tests glob.
```

Dependencies are listed exactly: `PUBLIC` for what the header needs,
`PRIVATE` for what only the `.cc` needs.

## What to copy from this

1. Header comment block per public symbol: purpose, contract, errors,
   lifetime, thread-safety.
2. `Create()` + private constructor + option struct.
3. Interface for the one dependency that touches the outside world; fake in
   the test; default to the real one.
4. Thread-safety annotations on every guarded member and method.
5. Validation with `InvalidArgument` and a message containing the value;
   preconditions with `DCHECK`.
6. Unnamed namespace for helpers; `NoDestructor` function-local static for
   the global.
7. Edge cases named and tested: boundary times, oversize requests, clock
   skew, "failed request consumes nothing".
8. Exact dependency lists in the build file.
