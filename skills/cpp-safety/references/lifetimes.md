# Lifetimes: references, views, iterators, lambdas

A non-owning handle is a promise that the owner is still alive. C++ does
not check the promise. This file gives the patterns that keep it true.

Contents:

1. [The four dangling shapes](#the-four-dangling-shapes)
2. [Function parameters and return values](#function-parameters-and-return-values)
3. [Storing non-owning handles in members](#storing-non-owning-handles-in-members)
4. [Container invalidation table](#container-invalidation-table)
5. [Lambdas and callbacks](#lambdas-and-callbacks)
6. [Temporaries and lifetime extension](#temporaries-and-lifetime-extension)
7. [Threads and async](#threads-and-async)
8. [Tools](#tools)

## The four dangling shapes

1. **Handle to a temporary.**
   `std::string_view v = GetName();` (function returns `std::string`);
   `absl::Span<const int> s = {1, 2, 3};` stored beyond the statement;
   `const char* p = std::string("x").c_str();`.
   Fix: bind the owner to a named variable first, or take a copy.
2. **Handle to a local returned or stored.**
   `const std::string& F() { std::string s; return s; }`;
   `callbacks.push_back([&local] { ... });`.
   Fix: return by value; capture by value or by owning pointer.
3. **Handle into a container that then mutates.**
   `auto& first = v[0]; v.push_back(x); use(first);`;
   `for (auto& x : v) if (...) v.erase(...)`.
   Fix: mutate after the loop; use indices; `erase`/`remove_if` idiom.
4. **Handle outliving the owner across objects.**
   `class Parser { std::string_view input_; }` constructed with a temporary
   string; `Observer* obs` registered and never unregistered before the
   observer dies.
   Fix: document and enforce ownership order; unregister in the destructor;
   use `weak_ptr` or generation ids when order cannot be enforced.

## Function parameters and return values

- A `string_view`/`Span`/`const T&` **parameter** is safe by construction:
  the argument outlives the call. It becomes unsafe only if the callee
  *stores* it.
- If a function stores its argument, take it by value (`std::string`,
  `std::vector<T>`, `std::shared_ptr<T>`) and move it into the member.
  Taking `string_view` and storing it is a trap for callers.
- Returning `const T&` to a member is fine for accessors (`const
  std::string& name() const`); the caller's responsibility is to not use it
  after the object is gone. Returning `string_view` to a member is
  equivalent and lets the implementation change.
- Returning a reference into a container the caller can mutate needs a
  comment ("invalidated by any insert").
- Never return a reference or view to a parameter taken by value or by
  `string_view`; the source may be a temporary at the call site:

  ```cpp
  std::string_view Trim(std::string_view s);      // ok: view into caller's data,
                                                  // caller's data outlives the statement
  std::string_view v = Trim(ReadLine());          // BUG: ReadLine() temp dies here
  std::string line = ReadLine(); auto v = Trim(line);  // ok
  ```

## Storing non-owning handles in members

Allowed only with a stated, enforceable guarantee. The acceptable shapes:

- **Parent owns child; child points to parent.** `Child(Parent& parent)`;
  `Parent` holds `std::unique_ptr<Child>` and constructs it. Document:
  "`parent_` outlives this object because it owns it."
- **Scoped helper.** An object created on the stack inside a function,
  holding a reference to something declared earlier in the same scope
  (`absl::MutexLock`, a `Span`-based cursor). Never returned or stored.
- **Arena/registry with explicit lifetime.** Handles into an arena that
  lives for the whole request; the request object owns the arena and
  everything that points into it.
- **Interned/static data.** `string_view` to a string literal or a
  process-lifetime table.

Anything else: copy, or use `shared_ptr` + `weak_ptr` to make the
lifetime checkable at runtime (`weak_ptr::lock()` returns null after the
owner dies). If you find yourself needing `weak_ptr` in many places, the
ownership design is wrong: fix the design.

## Container invalidation table

| Container | Operation | Invalidates |
|---|---|---|
| `std::vector` | `push_back`/`insert`/`emplace` when `size() == capacity()` | all iterators, pointers, references |
| `std::vector` | `insert`/`erase` at position p | everything at or after p |
| `std::vector` | `reserve`, `shrink_to_fit` | all (if reallocation happens) |
| `std::vector` | `clear` | all |
| `std::string` | any non-const operation | all (SSO makes even small ones move) |
| `std::deque` | `push_front/back` | iterators (references stay valid); insert in middle invalidates all |
| `std::list`, `std::map`, `std::set`, `std::unordered_map` | `erase(x)` | only x; other iterators and references stay valid |
| `std::unordered_map` | insert that rehashes | iterators (references and pointers stay valid) |
| `absl::flat_hash_map`/`set` | any insert (may rehash), `erase` | all iterators, pointers, references (erase: only the element, but don't rely on it) |
| `absl::node_hash_map` | insert | iterators; pointers/references to elements stay valid |
| `absl::btree_map` | insert/erase | all iterators, pointers, references |
| `absl::InlinedVector` | growth past inline capacity | all |
| `std::span`, `string_view` over any of the above | whatever invalidates the underlying storage | the view |

Safe loop mutation idioms:

```cpp
// Erase while iterating a node container:
for (auto it = m.begin(); it != m.end();) {
  if (Cond(*it)) it = m.erase(it); else ++it;
}
// Erase from a vector: erase-remove (or std::erase_if in C++20).
v.erase(std::remove_if(v.begin(), v.end(), Cond), v.end());
std::erase_if(v, Cond);
// Append while iterating: iterate by index up to the original size.
const size_t n = v.size();
for (size_t i = 0; i < n; ++i) if (Cond(v[i])) v.push_back(Derive(v[i]));
```

## Lambdas and callbacks

- `[&]` is only safe when the lambda is called before the enclosing scope
  exits (`std::for_each`, `absl::FunctionRef` parameters, `std::visit`).
- A lambda that is stored (`std::function`, `AnyInvocable`, a callback
  registry, a thread, a timer) must capture by value or capture owning
  smart pointers: `[self = shared_from_this()]`, `[data = std::move(data)]`.
- Capturing `this` implicitly (`[=]` in C++17 captures `this` by pointer)
  is the classic async use-after-free. Write `[this]` only when the lambda
  cannot outlive `this` (member function calling a synchronous algorithm);
  otherwise `[weak = weak_from_this()]` and check `lock()`.
- Callback registries: unregister in the destructor of the registered
  object, or hand out a token whose destruction unregisters (RAII
  subscription). A registry of raw pointers with no unregister path is a
  latent crash.
- Coroutines: parameters taken by reference are dangling after the first
  suspension if the caller's argument was a temporary; take by value.

## Temporaries and lifetime extension

- `const T& r = MakeT();` and `T&& r = MakeT();` extend the temporary to
  `r`'s scope. Only direct binding: `const T& r = MakeT().member` extends;
  `const T& r = MakeT().Get()` does **not** (`Get()` returns a reference into
  a temporary that dies at the semicolon).
- Range-for over a temporary works (`for (auto x : MakeVec())`), but
  `for (auto x : MakeObj().items())` dangles before C++23 (the object dies
  after `items()` returns). Bind the object first.
- Ternary with mixed value categories can create a temporary:
  `const std::string& s = cond ? a : "literal";` copies `a` into a temporary
  that is extended; fine, but subtly a copy.
- `std::min(a, b)` returns a reference; `const auto& m = std::min(x, 5);`
  dangles (the `5` temporary). Use `auto m = ...`.
- Structured bindings from a temporary: `auto [a, b] = MakeTuple();`
  copies; `auto& [a, b] = MakeTuple();` fails to compile; `const auto& [a,
  b] = MakeTuple();` extends. Use `auto`.

## Threads and async

- Data passed to a thread or task must be owned by the task (`std::move`
  into the lambda) or outlive it provably (joined before scope exit:
  `std::jthread`, a `BlockingCounter`, or a thread pool that is joined in
  the destructor of the owner).
- `absl::Notification`, futures, and `std::latch` establish the
  happens-before that makes "outlives" true; a `sleep` does not.
- Timers and callbacks from an I/O loop must hold `shared_ptr` or
  `weak_ptr` to their target, or be cancelled synchronously in the target's
  destructor (and the cancel must wait for an in-flight callback).

## Tools

- ASan with `ASAN_OPTIONS=detect_stack_use_after_return=1:
  detect_odr_violation=2:strict_string_checks=1:check_initialization_order=1`.
- Clang `-Wdangling`, `-Wdangling-gsl`, `-Wreturn-stack-address`,
  `-Wlifetime` (experimental in newer clangs); `[[clang::lifetimebound]]`
  on parameters whose lifetime the return value depends on:
  ```cpp
  std::string_view Trim(std::string_view s [[clang::lifetimebound]]);
  ```
  makes `Trim(std::string("x"))` bound to a `string_view` a compile-time
  warning. Abseil uses `ABSL_ATTRIBUTE_LIFETIME_BOUND` on its view-returning
  functions; add it to yours.
- `clang-tidy`: `bugprone-dangling-handle`, `bugprone-use-after-move`,
  `cppcoreguidelines-owning-memory`,
  `bugprone-stringview-nullptr`, `bugprone-unchecked-optional-access`.
- Hardened containers catch use of an invalid iterator in many cases
  (libc++ debug mode).
