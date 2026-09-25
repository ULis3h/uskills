# Static vs dynamic polymorphism, type erasure, and mixing them

Contents:

1. [The cost model](#the-cost-model)
2. [Dynamic: interfaces done right](#dynamic-interfaces-done-right)
3. [Static: templates and concepts](#static-templates-and-concepts)
4. [CRTP and deducing this](#crtp-and-deducing-this)
5. [Type erasure](#type-erasure)
6. [The ClickHouse layering: virtual at the block, template in the loop](#the-clickhouse-layering)
7. [Compile-time cost and how to contain it](#compile-time-cost)

## The cost model

| Mechanism | Per-call cost | Inlining | Extensibility | Where the code lives |
|---|---|---|---|---|
| direct/inlined call | 0 | yes | none | anywhere |
| template parameter | 0 | yes | compile time only | header |
| `std::variant` + visit | a switch (predictable) | yes, per alternative | closed set | anywhere |
| virtual function | indirect call, ~1-3 ns predicted, ~20 cycles if mispredicted; no inlining | no | open set | `.cc` |
| `absl::FunctionRef` | indirect call | no | any callable | anywhere |
| `absl::AnyInvocable` / `std::function` | indirect call + possible heap alloc at construction | no | any callable, storable | anywhere |
| `std::any` / hand-rolled erasure | indirect + alloc unless SBO | no | any type | anywhere |

A virtual call per request is free. A virtual call per byte is a 10x
slowdown. Everything else is in between and needs a benchmark.

## Dynamic: interfaces done right

```cpp
class Sink {
 public:
  virtual ~Sink() = default;
  Sink(const Sink&) = delete;              // polymorphic types are not copied by value
  Sink& operator=(const Sink&) = delete;

  // Public non-virtual API (NVI): can add checks, logging, batching.
  absl::Status Write(absl::Span<const uint8_t> data) {
    if (data.empty()) return absl::OkStatus();
    return WriteImpl(data);
  }
 protected:
  Sink() = default;
 private:
  virtual absl::Status WriteImpl(absl::Span<const uint8_t> data) = 0;
};
```

- Pure abstract, no data members, virtual destructor, non-copyable.
- `final` on leaf classes lets the compiler devirtualize when the static
  type is known.
- Don't add virtual functions "for testing" to a concrete class; extract
  the interface the test actually needs.
- Prefer returning `std::unique_ptr<Sink>` from factories and taking
  `Sink&` in consumers.
- Avoid virtual functions that return references to internals; they lock
  the representation.

## Static: templates and concepts

```cpp
template <typename T>
concept Hasher = requires(const T& h, absl::string_view s) {
  { h(s) } -> std::convertible_to<uint64_t>;
};

template <Hasher H = DefaultHasher>
class BloomFilter {
 public:
  explicit BloomFilter(size_t bits, H hasher = {}) : bits_(bits), hasher_(std::move(hasher)) {}
  void Add(absl::string_view key) { Set(hasher_(key) % bits_.size()); }
 private:
  std::vector<uint8_t> bits_;
  [[no_unique_address]] H hasher_;   // empty hasher costs no space
};
```

- Name requirements with concepts (or `static_assert` on traits in C++17)
  so errors say "H doesn't satisfy Hasher" instead of 200 lines of
  instantiation trace.
- `if constexpr` to branch on type properties instead of overloading
  helper functions.
- `[[no_unique_address]]` for empty policies.
- Keep the template surface thin: a template wrapper around a non-template
  core (`void SortImpl(void* data, size_t n, size_t elem_size, Compare)`)
  keeps code size and compile time in check where the inner loop does not
  need to be specialized.

## CRTP and deducing `this`

CRTP gives a base class access to the derived type without virtual calls:

```cpp
template <typename Derived>
class Comparable {
 public:
  friend bool operator!=(const Derived& a, const Derived& b) { return !(a == b); }
  friend bool operator>(const Derived& a, const Derived& b) { return b < a; }
  // ... derived provides == and <
};
class Version : public Comparable<Version> { /* == and < */ };
```

C++23 deducing `this` does the same with less ceremony:

```cpp
struct Comparable {
  template <typename Self>
  bool IsGreaterThan(this const Self& self, const Self& other) { return other < self; }
};
```

Use for: mixins (comparison operators, `AbslStringify` helpers,
intrusive ref counting), static interfaces where the derived type is
known at compile time. Do not use it to emulate virtual dispatch over a
heterogeneous collection; that is what virtual functions are for.

## Type erasure

When unrelated types must share a runtime interface but you don't want to
force inheritance on them (callables, drawables, any "duck-typed" value):

```cpp
// A small-buffer type-erased "Drawable" with value semantics.
class Drawable {
 public:
  template <typename T>
    requires requires(const T& t, Canvas& c) { t.Draw(c); }
  Drawable(T value) : self_(std::make_unique<Model<T>>(std::move(value))) {}
  Drawable(const Drawable& o) : self_(o.self_->Clone()) {}
  Drawable(Drawable&&) noexcept = default;
  void Draw(Canvas& c) const { self_->Draw(c); }
 private:
  struct Concept {
    virtual ~Concept() = default;
    virtual void Draw(Canvas&) const = 0;
    virtual std::unique_ptr<Concept> Clone() const = 0;
  };
  template <typename T> struct Model final : Concept {
    explicit Model(T v) : value(std::move(v)) {}
    void Draw(Canvas& c) const override { value.Draw(c); }
    std::unique_ptr<Concept> Clone() const override { return std::make_unique<Model>(value); }
    T value;
  };
  std::unique_ptr<Concept> self_;
};
std::vector<Drawable> scene = {Circle{...}, Text{"hi"}, Sprite{...}};
```

Off-the-shelf: `absl::AnyInvocable` (move-only callables),
`absl::FunctionRef` (non-owning), `std::function` (copyable, may
allocate), `std::any` (any value, no operations), `std::variant` when the
set is closed (faster, no allocation). Add a small-buffer optimization
only if profiling shows the allocation.

## The ClickHouse layering

ClickHouse's whole engine is a demonstration of "dynamic at the boundary,
static inside":

- `IColumn`, `IDataType`, `IFunction`, `IAggregateFunction` are virtual
  interfaces. A query plan calls `function->execute(block)` once per
  block of ~65k rows: the virtual call is amortized over tens of thousands
  of elements.
- Inside `execute`, the implementation dispatches **once** on the concrete
  column types (`checkAndGetColumn<ColumnVector<UInt64>>`, or a
  `castTypeToEither` over a list of types) into a template
  `executeImpl<T0, T1>` whose inner loop is a plain loop over `const T*`.
- Aggregate functions are templates on the key/value types instantiated
  for every supported type; the `IAggregateFunction` interface adds
  `addBatch(...)` methods so that even the per-row `add` call is a loop
  inside one virtual call.
- Hash tables, comparators, and sort are templates on key type; the
  choice of instantiation is made once per query from the runtime types.

Apply this shape anywhere: define the interface at the granularity of a
*batch* (a block, a page, a message, a frame), and make the per-element
work a template selected once. If your interface has a method that is
called per element, that is the bug.

## Compile-time cost

Templates and headers cost build time, which costs developer time and CI
minutes. Contain it:

- Put non-template, non-inline code in `.cc` files; a class that is never
  instantiated with more than one type does not need to be a template.
- Explicit instantiation (`template class Table<uint64_t>;` in one `.cc`,
  `extern template` in the header) for the handful of types you actually
  use.
- Forward-declare heavy types in headers used everywhere; Pimpl at the
  worst offenders.
- Measure with `-ftime-trace` (clang) and ClangBuildAnalyzer; the top
  headers by inclusion cost are usually a small number.
- Precompiled headers or C++20 modules for the standard library and
  Abseil.
