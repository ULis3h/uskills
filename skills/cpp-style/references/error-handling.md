# Error handling with `absl::Status` and `absl::StatusOr<T>`

Abseil's model: errors are ordinary return values carrying a canonical code
and a message. Programmer errors (violated preconditions) are not errors to
report; they crash with `CHECK`. This file covers how to write both.

## Choosing the mechanism

| Situation | Mechanism |
|---|---|
| Caller passed something invalid that documentation forbids | `CHECK(cond) << msg;` (or `DCHECK` if the check is expensive and the invariant is internal) |
| Runtime condition the caller can act on (not found, timeout, bad input) | `absl::Status` / `absl::StatusOr<T>` |
| A value that may legitimately be absent and absence is not a failure | `std::optional<T>` |
| Unrecoverable environment failure (OOM in a service that cannot degrade) | `LOG(FATAL)` / `CHECK` |
| Codebase uses exceptions (e.g. ClickHouse `DB::Exception`) | Throw on cold paths only; never in destructors, never as control flow, never across a hot loop iteration |

Do not return `bool`, `-1`, `nullptr`, or an empty string to mean failure.
They discard the reason, and callers forget to check them.

## Writing functions that fail

```cpp
absl::StatusOr<Config> LoadConfig(absl::string_view path) {
  ASSIGN_OR_RETURN(std::string text, ReadFile(path));   // propagate
  Config config;
  if (!ParseInto(text, &config)) {
    return absl::InvalidArgumentError(
        absl::StrCat("cannot parse config at ", path));
  }
  if (config.workers <= 0) {
    return absl::OutOfRangeError(absl::StrFormat(
        "workers must be positive, got %d (in %s)", config.workers, path));
  }
  return config;
}
```

Rules:

- Pick the **canonical code** that best tells the caller what to do:
  `InvalidArgument` (fix the input), `NotFound`, `AlreadyExists`,
  `FailedPrecondition` (system state wrong, retry won't help),
  `Unavailable` (retry may help), `DeadlineExceeded`, `ResourceExhausted`,
  `PermissionDenied`/`Unauthenticated`, `Unimplemented`, `Internal`
  (a bug), `Unknown` (only when wrapping something opaque).
- Messages are for humans: say what failed and include the offending value
  and location. Do not include the code name in the message (it's already
  there). Lower-case start, no trailing period, no newlines.
- Add context as errors propagate upward when the lower layer's message
  alone would not identify the operation. Keep the code:
  `return absl::Status(s.code(), absl::StrCat("loading ", path, ": ", s.message()));`
  Do not wrap so often that messages become `a: b: c: d: e`.
- Attach structured payloads (`status.SetPayload(...)`) only for data a
  program will act on, not for extra text.
- Mark Status-returning functions `[[nodiscard]]` (Abseil's `absl::Status`
  is already `ABSL_MUST_USE_RESULT`); never ignore a status silently. If
  ignoring is deliberate, write `.IgnoreError()` and a comment saying why.

## Propagation macros

Define (or use the codebase's) `RETURN_IF_ERROR` and `ASSIGN_OR_RETURN`:

```cpp
#define RETURN_IF_ERROR(expr)                        \
  do {                                               \
    if (absl::Status _st = (expr); !_st.ok()) {      \
      return _st;                                    \
    }                                                \
  } while (0)

#define ASSIGN_OR_RETURN(lhs, rexpr)                          \
  auto ASSIGN_OR_RETURN_CONCAT(_sor, __LINE__) = (rexpr);      \
  if (!ASSIGN_OR_RETURN_CONCAT(_sor, __LINE__).ok()) {         \
    return std::move(ASSIGN_OR_RETURN_CONCAT(_sor, __LINE__)).status(); \
  }                                                           \
  lhs = *std::move(ASSIGN_OR_RETURN_CONCAT(_sor, __LINE__))
```

(Real implementations handle the concatenation helper and `lhs` with
commas; if the project has `absl/status/status_macros.h` or a similar
internal header, use it.) Keep bodies flat: check, return, continue.
Deeply nested `if (s.ok()) { ... }` pyramids are a smell.

## Consuming `StatusOr<T>`

```cpp
absl::StatusOr<Config> config = LoadConfig(path);
if (!config.ok()) {
  LOG(ERROR) << "startup failed: " << config.status();
  return config.status();
}
Run(*config);           // or config->workers
```

- Check `ok()` before dereferencing. `*sor` on a failed `StatusOr` is UB in
  release and a `CHECK` failure in hardened builds.
- `std::move(sor).value()` to take the value out. `sor.value()` also works
  but `CHECK`-fails with a less useful message than an explicit check.
- In tests: `ASSERT_OK_AND_ASSIGN(Config c, LoadConfig(path));`,
  `EXPECT_THAT(LoadConfig(bad), StatusIs(absl::StatusCode::kInvalidArgument,
  HasSubstr("cannot parse")));`.

## Preconditions and assertions

- `CHECK(ptr != nullptr)` for conditions that indicate a bug in the caller;
  the failure message names the condition and the location.
- `DCHECK` for expensive internal checks that can be skipped in release.
  Never put side effects in a `DCHECK`.
- `CHECK_OK(status)` when failure is impossible by construction and you
  want the crash to explain itself.
- Document preconditions in the header ("`buffer` must be non-empty") and
  enforce the cheap ones.

## Exceptions, when the codebase uses them

If the project throws (Boost, Qt, ClickHouse, most non-Google code):

- Throw types derived from `std::exception` with a message that includes
  context; ClickHouse uses `DB::Exception(ErrorCodes::X, "fmt {}", args)`.
- Catch at boundaries (request handler, thread entry, main), not at every
  layer. Rethrow with context only if it adds information.
- Provide the strong or basic exception guarantee for every mutating
  operation, and say which in the comment. Use RAII, never manual cleanup.
- `noexcept` on move operations, destructors, swap, and anything called
  from a destructor.
- Never throw across a C or plugin ABI boundary. Convert to a status code.
- Never use exceptions for expected outcomes (item not found in a lookup,
  parse failure of user input on a hot path). ClickHouse, for example, keeps
  exceptions off per-row paths because unwinding is orders of magnitude
  slower than a branch.
