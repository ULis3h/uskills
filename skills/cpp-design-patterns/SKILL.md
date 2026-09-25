---
name: cpp-design-patterns
description: Choose and implement clean, zero-overhead C++ designs: static vs dynamic polymorphism, RAII and value semantics, strong types, option structs and builders, factories, type erasure, CRTP and concepts, variant-based visitors and state machines, Pimpl, observer/callback lifetimes, registries and plugins, dependency injection for testability. Use this skill whenever the user asks how to structure, architect, refactor, or "design" C++ code, mentions a design pattern by name (factory, strategy, visitor, observer, singleton, builder, adapter, decorator, command, state), asks about interfaces, abstract classes, inheritance vs composition, templates vs virtual functions, extensibility, testability, or dependency injection, or when existing code has deep inheritance, god classes, or tangled ownership that needs untangling.
---

# C++ design patterns, the modern way

Design patterns in C++ are mostly about one decision made well: **where
does the flexibility live: in the type system at compile time, or in an
object at run time?** Abseil's answer is "the simplest thing the reader
can follow"; ClickHouse's answer is "static where it's hot, dynamic where
it's a boundary". Both agree on value semantics, explicit ownership, small
interfaces, and composition over inheritance.

Reference files:

- `references/catalog.md`: each pattern with when, how, a minimal modern
  implementation, and the anti-pattern it replaces. Read the entry you
  need.
- `references/polymorphism.md`: the static-vs-dynamic decision in depth,
  type erasure, CRTP, concepts, and how ClickHouse mixes them.

## 1. Decide the axis of variation first

Before picking a pattern, answer:

1. **What varies?** (algorithm, data representation, backend, policy,
   lifecycle)
2. **When is it known?** Compile time (a template parameter), program
   start (configuration), or per call (runtime data)?
3. **Is it on a hot path?** Per-element dispatch must be static or hoisted
   per batch; per-request dispatch can be virtual.
4. **Who else needs to extend it?** Closed set (you own all variants) → a
   `variant` or an enum switch; open set (plugins, other teams) → an
   abstract interface.
5. **Does it cross a boundary?** Shared library, ABI, C API, or a large
   compile firewall → dynamic and Pimpl.

Then use the smallest mechanism that fits:

| Variation is | Mechanism |
|---|---|
| Fixed at compile time, hot | template parameter, `if constexpr`, concepts |
| Closed set of alternatives, value-like | `std::variant` + `std::visit` / overloaded lambdas |
| Open set, object identity, cold or per-batch | abstract base class with virtual functions (an "interface") |
| Callable behavior, stored | `absl::AnyInvocable` / `std::function`; passed only: `absl::FunctionRef` |
| Small fixed set of modes | `enum class` + exhaustive `switch` |
| Optional behavior | `std::optional<Callback>`, a null-object default |
| Configuration | an option struct with defaults + designated initializers |

## 2. Principles

- **Value semantics first.** Types that copy, move, compare, and hash like
  `int` are the easiest to test and to reason about. Reach for identity
  (pointers, virtuals) only when an object *is* something with a lifetime
  (a connection, a thread, a file).
- **Composition over inheritance.** Inherit to implement an interface;
  never to reuse code. Depth > 2 is a smell; a base class with data
  members and protected accessors is a smell.
- **Small interfaces.** An abstract class with one to three pure virtual
  functions; split roles (`Reader`, `Writer`) rather than a `Stream` with
  twelve. Depend on the narrowest interface you can.
- **Explicit dependencies.** A class gets what it needs through its
  constructor (references, `unique_ptr`, or interfaces), never through
  globals or singletons. This is what makes it testable with fakes.
- **Zero overhead where it matters.** A pattern must not add allocation,
  indirection, or synchronization to a hot loop. Measure if unsure.
- **One way to construct a valid object.** Factory function returning
  `absl::StatusOr<T>` for fallible construction; no `Init()` phases.
- **Immutability as the default.** Immutable objects are trivially
  thread-safe, cacheable, and easy to reason about. Build via an options
  struct or a builder, then freeze.
- **Name the concept.** A `struct Millimeters { double value; }` or an
  `enum class Mode` beats a `double` or `bool` in every signature it
  appears in.

## 3. Patterns you will use daily

- **RAII / scope guard**: every resource in a destructor;
  `absl::Cleanup` for ad-hoc rollback.
- **Strong typedef / tag type**: `struct UserId { int64_t v; }`, comparison
  and hash defaulted. Prevents argument swaps.
- **Option struct** with designated initializers instead of a builder for
  ≤ ~8 parameters; a **builder** only when validation between fields or
  incremental construction is required.
- **Factory function** (`static absl::StatusOr<Foo> Create(...)`) for
  validation; **factory registry** (`absl::flat_hash_map<string,
  Creator>`) for name-based creation of plugins, populated by static
  registration objects.
- **Interface + fake** for anything with I/O or time (`Clock`,
  `FileSystem`, `Transport`); inject through the constructor.
- **Strategy** as a template parameter when hot (comparators, hashers,
  allocators), as an interface when configured at runtime.
- **Visitor** via `std::variant` + `absl::Overload`/overloaded lambdas
  for closed ASTs and messages; classic double dispatch only when the
  hierarchy is open.
- **State machine** as an `enum class` + switch, or `std::variant` of
  state structs when states carry data.
- **Pimpl** for stable ABI or heavy private includes; not by default (it
  costs an allocation and an indirection).
- **Observer** with RAII subscriptions (a token whose destructor
  unsubscribes) so listeners can never dangle.
- **Type erasure** (`AnyInvocable`, `std::any`, a hand-rolled small-buffer
  wrapper) to give a family of unrelated types one runtime interface
  without inheritance.
- **CRTP / deducing `this`** for mixins and static interfaces with no
  virtual cost; concepts to name the requirements.
- **Null object** (a do-nothing implementation) instead of null checks
  everywhere; **optional** when absence is data.

## 4. Anti-patterns and their replacements

| Smell | Replace with |
|---|---|
| Singleton with mutable state | pass the dependency in; if truly process-global, a function-local static of an immutable object |
| `Init()`/`Setup()` after construction | factory function, constructor takes everything |
| Deep class hierarchy for code reuse | composition: members that do the work; free functions |
| God class (`Manager`, `Context`, `Utils`) | split by responsibility; namespaced free functions |
| `bool` flags controlling behavior | `enum class`, or two functions |
| Getter/setter pairs on every field | a struct with public fields, or real operations with names |
| `std::shared_ptr` everywhere | one owner (`unique_ptr`), borrowers get `T&`/`T*` |
| `dynamic_cast` chains | `std::variant` + visit, or a virtual method that does the job |
| Template everything "for flexibility" | template only what varies at compile time; keep interfaces in `.cc` |
| Virtual call per element in a loop | hoist dispatch to the batch; template inner kernel |
| Exceptions as control flow | `StatusOr`, `optional`, `expected` |
| Global registries with static init order dependencies | function-local static registry, explicit `RegisterAll()` |
| Interface with 15 methods | several small interfaces, composed |
| Callback registry of raw pointers | RAII subscription tokens or `weak_ptr` |

## 5. Workflow

1. Write the call sites for the *two or three* variants you actually have
   today. Do not design for hypothetical variants.
2. Pick the mechanism from the table in §1. Prefer the one with less
   machinery; upgrade later when a real second variant arrives (a
   `variant` can become an interface in an afternoon; the reverse is
   harder).
3. Keep the pattern's machinery in one place (one header), with a comment
   naming the pattern and the reason.
4. Make it testable: the seam you introduced should let a test substitute
   a fake without linking the real dependency.
5. If the pattern is on a hot path, benchmark against the plain version
   (see `cpp-performance`).
