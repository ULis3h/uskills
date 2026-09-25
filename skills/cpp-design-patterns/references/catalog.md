# Pattern catalog for modern C++

Each entry: when to use, a minimal implementation in current C++ (17/20),
and what it replaces. Implementations favor Abseil types; substitute
`std::` equivalents where the codebase does.

Contents:

1. [RAII and scope guards](#raii-and-scope-guards)
2. [Strong types and tag types](#strong-types-and-tag-types)
3. [Option structs and builders](#option-structs-and-builders)
4. [Factory functions and registries](#factory-functions-and-registries)
5. [Interfaces, fakes, dependency injection](#interfaces-fakes-dependency-injection)
6. [Strategy and policy](#strategy-and-policy)
7. [Variant visitor and state machines](#variant-visitor-and-state-machines)
8. [Pimpl](#pimpl)
9. [Observer with safe lifetimes](#observer-with-safe-lifetimes)
10. [Command and undo](#command-and-undo)
11. [Null object](#null-object)
12. [Object pool and arena](#object-pool-and-arena)
13. [Singleton, when unavoidable](#singleton-when-unavoidable)
14. [Iterator and range adaptors](#iterator-and-range-adaptors)
15. [Decorator and adapter](#decorator-and-adapter)

## RAII and scope guards

Use for every resource and every "undo on early exit".

```cpp
class FileDescriptor {
 public:
  static absl::StatusOr<FileDescriptor> Open(absl::string_view path, int flags);
  FileDescriptor(FileDescriptor&& o) noexcept : fd_(std::exchange(o.fd_, -1)) {}
  FileDescriptor& operator=(FileDescriptor&& o) noexcept {
    if (this != &o) { Close(); fd_ = std::exchange(o.fd_, -1); }
    return *this;
  }
  ~FileDescriptor() { Close(); }
  int get() const { return fd_; }
 private:
  explicit FileDescriptor(int fd) : fd_(fd) {}
  void Close() { if (fd_ >= 0) { ::close(fd_); fd_ = -1; } }
  int fd_ = -1;
};

// Ad-hoc cleanup:
absl::Status Process() {
  BeginTransaction();
  auto rollback = absl::MakeCleanup([&] { RollbackTransaction(); });
  RETURN_IF_ERROR(Step1());
  RETURN_IF_ERROR(Step2());
  std::move(rollback).Cancel();   // success: keep the transaction
  CommitTransaction();
  return absl::OkStatus();
}
```

Replaces: `goto cleanup`, `try { } catch { cleanup; throw; }`, forgotten
`close()` on early return.

## Strong types and tag types

```cpp
struct UserId {
  int64_t value = 0;
  friend bool operator==(UserId, UserId) = default;
  friend auto operator<=>(UserId, UserId) = default;
  template <typename H> friend H AbslHashValue(H h, UserId id) {
    return H::combine(std::move(h), id.value);
  }
  template <typename Sink> friend void AbslStringify(Sink& s, UserId id) {
    absl::Format(&s, "UserId(%d)", id.value);
  }
};
void Transfer(UserId from, UserId to, Money amount);   // can't swap arguments by mistake
```

For units, `std::chrono::duration` and `absl::Duration` already exist; use
them instead of `int timeout_ms`. Tag types select overloads or unlock
private constructors:

```cpp
struct FromBytesTag {};
inline constexpr FromBytesTag kFromBytes;
Buffer(FromBytesTag, absl::Span<const uint8_t> bytes);
```

Replaces: `int` and `bool` parameters with positional meaning; `typedef`
aliases (which give no type safety).

## Option structs and builders

Option struct (default choice):

```cpp
struct ServerOptions {
  int port = 8080;
  int num_threads = 4;
  absl::Duration idle_timeout = absl::Minutes(5);
  std::optional<std::string> tls_cert_path;
};
absl::StatusOr<Server> MakeServer(ServerOptions options = {});
auto server = MakeServer({.port = 9090, .num_threads = 16});
```

Builder, when construction is incremental or validation spans fields:

```cpp
class QueryBuilder {
 public:
  QueryBuilder& Select(absl::string_view column) &;   // lvalue-only chaining
  QueryBuilder&& Select(absl::string_view column) &&; // rvalue chaining
  QueryBuilder& Where(Predicate p) &;
  absl::StatusOr<Query> Build() &&;   // consumes the builder; validates
 private:
  std::vector<std::string> columns_;
  std::vector<Predicate> predicates_;
};
ASSIGN_OR_RETURN(Query q, QueryBuilder().Select("a").Where(p).Build());
```

Replaces: constructors with 6 positional parameters, telescoping
constructors, setters on the final object.

## Factory functions and registries

Fallible construction:

```cpp
class Codec {
 public:
  static absl::StatusOr<std::unique_ptr<Codec>> Create(const CodecConfig& cfg);
 protected:
  Codec() = default;
};
```

Name-based creation with static registration (plugins, formats, functions):

```cpp
class CodecRegistry {
 public:
  using Factory = absl::AnyInvocable<absl::StatusOr<std::unique_ptr<Codec>>(
      const CodecConfig&) const>;
  static CodecRegistry& Instance() {   // function-local static: no init-order fiasco
    static auto* registry = new CodecRegistry;
    return *registry;
  }
  void Register(std::string name, Factory f) ABSL_LOCKS_EXCLUDED(mu_);
  absl::StatusOr<std::unique_ptr<Codec>> Create(absl::string_view name,
                                                const CodecConfig& cfg) const;
 private:
  mutable absl::Mutex mu_;
  absl::flat_hash_map<std::string, Factory> factories_ ABSL_GUARDED_BY(mu_);
};

// In lz4_codec.cc:
namespace {
const bool kRegistered = [] {
  CodecRegistry::Instance().Register("lz4", [](const CodecConfig& c) {
    return Lz4Codec::Create(c);
  });
  return true;
}();
}  // namespace
```

Static registration works only if the TU is linked (`--whole-archive` or
`alwayslink`); for static libraries, prefer an explicit `RegisterAllCodecs()`
called from `main`. ClickHouse uses explicit `registerFunctions()`,
`registerAggregateFunctions()`, etc. for exactly this reason.

## Interfaces, fakes, dependency injection

```cpp
class Clock {
 public:
  virtual ~Clock() = default;
  virtual absl::Time Now() const = 0;
};
class SystemClock final : public Clock {
 public:
  absl::Time Now() const override { return absl::Now(); }
};
class FakeClock final : public Clock {
 public:
  absl::Time Now() const override { return now_; }
  void Advance(absl::Duration d) { now_ += d; }
 private:
  absl::Time now_ = absl::UnixEpoch();
};

class RateLimiter {
 public:
  explicit RateLimiter(const Clock& clock, RateLimiterOptions o) : clock_(clock), o_(o) {}
  // ...
 private:
  const Clock& clock_;   // documented: caller guarantees clock outlives limiter
  RateLimiterOptions o_;
};
```

Rules: interfaces are pure abstract with a virtual destructor, no data;
production implementation and fake live next to the interface; the
consumer takes the interface by reference or `unique_ptr` (if it owns it).
Prefer a hand-written fake to a mock: fakes model behavior, mocks model
call sequences. Do not create an interface for a class that has no second
implementation and no I/O; a value type with a pure function is already
testable.

## Strategy and policy

Runtime strategy (configured once, called per request):

```cpp
class CompressionStrategy { public: virtual ~CompressionStrategy() = default;
  virtual absl::StatusOr<std::string> Compress(absl::string_view) const = 0; };
```

Compile-time policy (called per element, must inline):

```cpp
template <typename Hash = absl::Hash<Key>, typename Eq = std::equal_to<Key>>
class Table { /* Hash and Eq calls inline into the probe loop */ };

// ClickHouse style: pick the specialization once per batch.
template <typename T> void SumImpl(const T* data, size_t n, T& out);
void Sum(const IColumn& col, Field& out) {
  switch (col.type()) {
    case TypeIndex::Int32:  return SumImpl<int32_t>(...);
    case TypeIndex::Float64: return SumImpl<double>(...);
    // ...
  }
}
```

Use `absl::FunctionRef` when the strategy is a callable passed for the
duration of one call, `AnyInvocable` when stored.

## Variant visitor and state machines

Closed set of node types, value semantics, no virtual calls:

```cpp
struct Literal { int64_t value; };
struct Column  { std::string name; };
struct BinaryOp;
using Expr = std::variant<Literal, Column, std::unique_ptr<BinaryOp>>;
struct BinaryOp { char op; Expr lhs, rhs; };

int64_t Eval(const Expr& e, const Row& row) {
  return std::visit(absl::Overload(
      [&](const Literal& l) { return l.value; },
      [&](const Column& c) { return row.Get(c.name); },
      [&](const std::unique_ptr<BinaryOp>& b) {
        int64_t l = Eval(b->lhs, row), r = Eval(b->rhs, row);
        return b->op == '+' ? l + r : l * r;
      }), e);
}
```

State machine with data-carrying states:

```cpp
struct Idle {};
struct Connecting { absl::Time started; int attempt; };
struct Connected { Socket socket; };
struct Failed { absl::Status why; };
using State = std::variant<Idle, Connecting, Connected, Failed>;

State OnEvent(State s, const Event& ev) {
  return std::visit(absl::Overload(
      [&](Idle) -> State { return Connecting{absl::Now(), 1}; },
      [&](Connecting c) -> State { /* ... */ },
      // ...
      ), std::move(s));
}
```

Adding a type to the variant makes every non-exhaustive visitor a compile
error, which is the point. Use classic virtual `Accept(Visitor&)` only
when the hierarchy must be extensible by other modules.

## Pimpl

```cpp
// widget.h
class Widget {
 public:
  Widget();
  ~Widget();                       // defined in .cc where Impl is complete
  Widget(Widget&&) noexcept;
  Widget& operator=(Widget&&) noexcept;
  void Draw();
 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
// widget.cc
class Widget::Impl { /* heavy private members, heavy includes */ };
Widget::Widget() : impl_(std::make_unique<Impl>()) {}
Widget::~Widget() = default;
```

Use for: ABI stability of a shared library, hiding a heavy dependency
(Boost, a vendor SDK) from a widely included header. Not for: everything
(each Pimpl is an allocation and an indirection, and it hides the
class's size from the optimizer).

## Observer with safe lifetimes

```cpp
class EventBus {
 public:
  using Handler = absl::AnyInvocable<void(const Event&)>;
  class Subscription {   // RAII: destroying it unsubscribes
   public:
    Subscription() = default;
    Subscription(Subscription&&) noexcept;
    Subscription& operator=(Subscription&&) noexcept;
    ~Subscription() { Reset(); }
    void Reset();
   private:
    friend class EventBus;
    Subscription(EventBus* bus, uint64_t id) : bus_(bus), id_(id) {}
    EventBus* bus_ = nullptr;
    uint64_t id_ = 0;
  };
  [[nodiscard]] Subscription Subscribe(Handler h);
  void Publish(const Event& e);   // copies handler list under lock, calls outside the lock
 private:
  absl::Mutex mu_;
  uint64_t next_id_ ABSL_GUARDED_BY(mu_) = 1;
  absl::flat_hash_map<uint64_t, std::shared_ptr<Handler>> handlers_ ABSL_GUARDED_BY(mu_);
};
```

The subscriber stores the `Subscription` as a member, so it cannot outlive
the subscriber. `Publish` must not hold the lock while calling handlers
(a handler that subscribes or unsubscribes would deadlock), and must
tolerate a handler removed during dispatch (hence `shared_ptr<Handler>`
copies). For single-threaded UIs a plain vector of `(id, handler)` and
the same token works.

## Command and undo

```cpp
class Command {
 public:
  virtual ~Command() = default;
  virtual absl::Status Apply(Document& doc) = 0;
  virtual absl::Status Revert(Document& doc) = 0;
};
class History {
 public:
  absl::Status Execute(std::unique_ptr<Command> c, Document& doc) {
    RETURN_IF_ERROR(c->Apply(doc));
    undo_.push_back(std::move(c));
    redo_.clear();
    return absl::OkStatus();
  }
  // Undo/Redo move commands between the two stacks.
 private:
  std::vector<std::unique_ptr<Command>> undo_, redo_;
};
```

For value-like documents, "undo" can be simply a persistent/immutable
snapshot (copy-on-write): often simpler and more robust than inverse
operations.

## Null object

```cpp
class Logger { public: virtual ~Logger() = default; virtual void Log(absl::string_view) = 0; };
class NullLogger final : public Logger { public: void Log(absl::string_view) override {} };
const Logger& NoLogging() { static const NullLogger* l = new NullLogger; return *l; }

class Service {
 public:
  explicit Service(const Logger& logger = NoLogging());
};
```

Replaces `if (logger_ != nullptr) logger_->Log(...)` at every call site.

## Object pool and arena

Pool for expensive-to-construct reusable objects (connections, large
buffers):

```cpp
template <typename T>
class Pool {
 public:
  class Lease {   // RAII: returns the object on destruction
   public:
    T& operator*() { return *obj_; }
    ~Lease() { if (obj_) pool_->Return(std::move(obj_)); }
   private:
    friend class Pool; Lease(Pool* p, std::unique_ptr<T> o);
    Pool* pool_; std::unique_ptr<T> obj_;
  };
  Lease Acquire();   // pops a free object or constructs one
 private:
  void Return(std::unique_ptr<T> o);
  absl::Mutex mu_;
  std::vector<std::unique_ptr<T>> free_ ABSL_GUARDED_BY(mu_);
};
```

Arena for many small same-lifetime objects: see
`cpp-performance/references/memory.md`. Both replace `new`/`delete`
churn and, for pools, expensive setup per use.

## Singleton, when unavoidable

Only for process-wide, immutable-after-init resources (a registry, a
`Clock` implementation, flag values). Then:

```cpp
const Config& GlobalConfig() {
  static const Config* const config = LoadConfigOrDie();   // leaked, never destroyed
  return *config;
}
```

Function-local static: initialized on first use, thread-safe, no
destruction-order problems. Never a class with `static Instance()` that
holds mutable state everyone reaches into: pass that state explicitly.

## Iterator and range adaptors

To expose a sequence without exposing the container:

- Return `absl::Span<const T>` when storage is contiguous.
- Return a lightweight view type with `begin()`/`end()` for non-contiguous
  or lazy sequences; C++20 `std::ranges::subrange` and `std::views::*`
  cover most cases.
- Accept `absl::FunctionRef<void(const T&)>` ("internal iteration") when
  the traversal is complex and callers just want each element: simplest
  to implement, easiest to make fast, and no iterator invalidation rules.
- Write a full iterator class only for a general-purpose container.

## Decorator and adapter

Decorator wraps an interface with the same interface:
`class LoggingTransport : public Transport { std::unique_ptr<Transport>
inner_; ... }`. Prefer it over subclassing the concrete transport. Adapter
converts one interface to another; keep it thin and stateless where
possible. Both are cheap when they operate per request; if applied per
element (e.g. a decorating `IColumn` that intercepts every `get()`),
they belong in the batch layer instead.
