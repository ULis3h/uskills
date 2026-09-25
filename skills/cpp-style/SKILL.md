---
name: cpp-style
description: Write and refactor C++ in the Abseil / Google style: reader-first APIs, value semantics, explicit ownership, absl::Status/StatusOr error handling, string_view/Span parameters, no surprising behavior. Use this skill whenever you write, edit, or review any C++ code (.h/.cc/.cpp/.hpp), design a C++ API or class, choose parameter and return types, name things, handle errors, or decide how to structure headers and namespaces, even if the user does not mention Abseil or "style". It is the default coding philosophy for this repository's C++ work; pair it with cpp-performance for hot paths, cpp-safety for lifetime and UB questions, and cpp-design-patterns for architecture.
---

# C++ style: the Abseil way

Abseil's philosophy in one sentence: **code is read far more often than it is
written, so optimize for the reader at the call site, and make the obvious
thing the correct thing.** Everything below follows from that. When a rule
here conflicts with an existing codebase's conventions, follow the codebase
and mention the difference, but keep the *reasoning* (clarity, explicit
ownership, no surprises) intact.

Read `references/exemplar.md` **before writing a new class or module**: it
is a complete header + implementation + test written to this standard, with
notes on each decision. Imitating its shape gets most of the rules right
without consulting them one by one. Read `references/abseil-tips.md` when
you need the specific rule for a situation (string building, initialization
forms, overloads, lifetimes, option structs, and so on). It is a condensed
catalog of the Abseil "Tip of the Week" canon. Read
`references/api-design.md` when designing a new class, function family, or
library boundary. Read `references/error-handling.md` when the code needs to
report failures.

## 1. Core principles

1. **Clarity at the call site beats clarity at the definition.** Judge every
   signature by how its *calls* read: `Resize(width, height)` beats
   `Resize(std::pair<int,int>)`; `Config{.timeout = 5s, .retries = 3}` beats
   `Config(5, 3)`. If a call needs a comment to be understood, the API is
   wrong.
2. **Boring is good.** Prefer the plain, well-known construct over the clever
   one. Template metaprogramming, macros, and operator overloading need to
   earn their place with a concrete reader benefit.
3. **No surprises.** A function does exactly what its name says, nothing more.
   No hidden global state, no silent fallbacks, no "convenient" implicit
   conversions.
4. **Ownership is explicit in the type.** `std::unique_ptr<T>` owns, `T*` and
   `T&` borrow, `std::shared_ptr<T>` is a design decision that needs a
   comment. Never pass ownership through a raw pointer.
5. **Value semantics by default.** Small, regular types that copy and compare
   correctly are easier to reason about than reference-laden object graphs.
   Reach for inheritance only when you need runtime polymorphism.
6. **Errors are values.** Report failures with `absl::Status` /
   `absl::StatusOr<T>` (or the codebase's equivalent). Exceptions, where the
   codebase allows them, are for genuinely exceptional, non-local failures,
   never for control flow.
7. **Const is a promise.** Mark everything `const` that can be; `constexpr`
   when it can be computed at compile time.

## 2. Naming and layout (Google style)

| Thing | Convention | Example |
|---|---|---|
| Types, functions, methods | `PascalCase` | `class ByteBuffer`, `ParseHeader()` |
| Variables, parameters | `snake_case` | `bytes_read` |
| Data members | `snake_case_` (trailing underscore; structs without) | `buffer_`, `size_` |
| Constants (`constexpr`, `const` at namespace/class scope), enumerators | `kPascalCase` | `kMaxRetries`, `Color::kRed` |
| Namespaces | short `lowercase`, one word if possible | `namespace net {` |
| Macros | `SCREAMING_SNAKE`, project-prefixed, avoided | `MYLIB_ASSERT` |
| Files | `snake_case.h` / `snake_case.cc`, tests `_test.cc` | `byte_buffer.h` |
| Template parameters | `PascalCase` (`T`, `Iterator`, `Alloc`) | |
| Getters | noun, no `get` prefix; setters `set_x()` | `size()`, `set_name()` |

Layout rules that matter for readability:

- 80-column limit is the Google default; many codebases use 100 or 120. Match
  the project's `.clang-format` and never hand-format.
- Include order: the header this file implements, then C system, C++ standard,
  other libraries, then project headers, each group sorted. Include what you
  use (IWYU): every symbol you use is declared by a header you include
  directly. Prefer includes over forward declarations unless the header is
  known to be heavy and the forward declaration is stable.
- Every header has an include guard (`PROJECT_PATH_FILE_H_`) or `#pragma once`
  if the project already uses it.
- File-local helpers go in an unnamed namespace in the `.cc`, never `static`
  functions in headers.
- No `using namespace` anywhere, and no `using` declarations in headers at
  namespace scope. Namespace aliases are fine inside a `.cc`.
- Order class members: `public`, `protected`, `private`; within each: types,
  constants, factory functions, constructors/destructor, methods, then data
  members last.

## 3. Function signatures

Choose parameter types by *what the function needs*, not by what the caller
happens to have.

| Need | Parameter type |
|---|---|
| Read a string, don't store it | `absl::string_view` (`std::string_view`) |
| Read a contiguous sequence, don't store | `absl::Span<const T>` (`std::span<const T>`) |
| Mutate a caller's sequence in place | `absl::Span<T>` |
| Read a large object, don't store | `const T&` |
| Store or consume a value | `T` by value, then `std::move` it into place |
| Take ownership | `std::unique_ptr<T>` by value |
| Optional non-owning object | `T*` (documented nullable) or `std::optional<T>` for small values |
| Call a callback now and not keep it | `absl::FunctionRef<R(Args...)>` |
| Store a callback | `absl::AnyInvocable<R(Args...)>` (move-only, cheap) |
| Output | the **return value**, never an out-parameter unless there are several |

Additional rules:

- Return values, don't fill out-parameters. If you need two results, return a
  small struct with named fields, or `std::pair` only when the pairing is
  obvious.
- Mark single-argument constructors and conversion operators `explicit`.
  Mark multi-argument constructors `explicit` too unless implicit
  brace-conversion is a deliberate feature (`std::pair`-like types).
- Prefer `[[nodiscard]]` on functions whose result is the whole point
  (factories, `Status`-returning functions, pure computations).
- Avoid `bool` parameters: `Open(path, /*create=*/true)` is a smell. Use an
  `enum class` or an option struct.
- Avoid overloads that differ only in subtle ways. An overload set should
  behave as one function with one documented contract.
- Default arguments only on non-virtual functions and only when every caller
  wants the same default; otherwise use an option struct.
- Non-member, non-friend functions are preferred for operations that do not
  need private access. Put them in the same namespace as the type so ADL
  finds them.

## 4. Types and classes

- Prefer plain `struct` with public fields for passive data; use `class` with
  invariants and private data when there is something to protect.
- Follow the **rule of zero**: rely on members' destructors and `= default`.
  If you must write one special member, write or `= delete` all of them.
- Prefer factory functions (`static absl::StatusOr<Foo> Create(...)`) over
  constructors that can fail plus `Init()` methods. Objects should be fully
  usable after construction.
- Use `= default` in the header for trivial special members so the type stays
  trivially copyable where possible, but define non-trivial ones in the `.cc`.
- Use `enum class` always; give enumerators `k` names; use exhaustive
  `switch` without `default` so a new enumerator is a compile warning.
- Prefer `std::optional<T>` to sentinel values, and `absl::StatusOr<T>` when
  the absence is an error with a reason.
- Move-only types should be the norm for resource handles. Mark move
  constructors/assignments `noexcept`.
- Avoid `mutable`, `friend`, and `const_cast` unless the invariant genuinely
  needs it, and comment why.
- Every polymorphic base class has a `virtual` destructor (or a `protected`
  non-virtual one). Use `override` (and `final` where deliberate), never a
  bare `virtual` on an overriding function.

## 5. Strings

- Parameters: `absl::string_view`. Never `const std::string&` unless you need
  a `std::string` specifically (e.g. to hand to a legacy API by reference).
- Never store a `string_view` unless the pointed-to data is guaranteed to
  outlive the holder; that guarantee belongs in a comment.
- Build strings with `absl::StrCat`, `absl::StrAppend`, `absl::StrFormat`,
  `absl::StrJoin`, `absl::Substitute`. Do not chain `operator+`; do not use
  `std::stringstream` or `sprintf`.
- Split with `absl::StrSplit(text, ',')`, parse numbers with
  `absl::SimpleAtoi` and friends, never `atoi`/`strtol`.
- Prefer raw string literals for regexes and multi-line text.

## 6. Initialization, constants, and globals

- Use `=` for simple value initialization (`int n = 0;`), `{}` for aggregates
  and when narrowing must be an error, `()` for constructor calls that would
  otherwise pick an `initializer_list` overload (`std::vector<int>(3, 0)`).
- Constants: `inline constexpr` at namespace scope in headers, `static
  constexpr` in classes. Never non-trivially-destructible globals (no
  `static const std::string kName = "..."`): use `constexpr
  absl::string_view`, `const char[]`, or a function-local static returning a
  reference to a leaked object.
- `std::vector<int> v = {1, 2, 3};` uses braces for element lists. Prefer
  designated initializers (`Options{.timeout = 5s}`) for structs.
- Declare variables in the narrowest scope, as late as possible, initialized
  at declaration, `const` when never reassigned.

## 7. Comments and documentation

- Comment the **why**, not the what. Code that needs a "what" comment should
  be rewritten.
- Every public declaration in a header has a comment describing contract,
  ownership, thread-safety, and error conditions. Do not repeat the name.
- Use `// TODO(username): ...` or `// TODO(b/12345): ...` with an owner.
- Document invariants and preconditions with `CHECK`/`DCHECK` (or
  `assert`) in addition to prose, so they are enforced.

## 8. Tests

- One behavior per test; name `TEST(ThingUnderTest, BehaviorWhenCondition)`.
- Use GoogleTest matchers (`EXPECT_THAT(v, ElementsAre(1, 2))`,
  `IsOkAndHolds`, `StatusIs`) so failures print useful diffs.
- No logic in tests: no loops that hide which case failed, no conditionals.
  Table-driven tests are fine when each row is self-describing.
- Test the public contract, not private implementation. Avoid friend tests.
- Prefer fakes and simple stubs over mocks; a test that only verifies which
  methods were called is a change detector.

## 9. Things that are always wrong

- `using namespace std;`
- Raw `new`/`delete` outside of allocator or arena implementations.
- Owning raw pointers, `T*` returned from a factory.
- Output parameters where a return value works.
- Catching exceptions to ignore them, or returning `bool` for success while
  swallowing the reason.
- `std::endl` (use `'\n'`), C-style casts, `#define` constants, `NULL`.
- Non-`explicit` converting constructors.
- Storing `string_view` / `Span` / references without a lifetime comment.
- Growing a `std::string` with `+=` in a loop when `StrAppend`/`reserve` was
  available.
- `std::shared_ptr` used because ownership was unclear rather than shared.

## Workflow when writing or editing code

1. Identify the reader: the person who calls this API. Sketch the call site
   first, then the signature.
2. Decide ownership and lifetimes for every pointer/reference/view, and write
   them into the signature and doc comment.
3. Write the happy path with `Status`/`StatusOr` plumbing from the start;
   errors added later are always messier.
4. Check the table in §3 for every parameter, §4 for every class.
5. Run the repository's formatter and `clang-tidy`; fix, do not suppress.
6. Add or update a test named after the behavior you changed.
