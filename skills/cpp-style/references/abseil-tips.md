# Abseil Tip-of-the-Week canon, condensed

A catalog of the rules from Abseil's "Tip of the Week" series that come up
most often when writing everyday C++. Each entry gives the rule, the reason,
and a minimal example. Numbers refer to the original tips
(https://abseil.io/tips/) so you can point a reader at the full text.

Contents:

1. [Strings](#strings)
2. [Function signatures and return values](#function-signatures-and-return-values)
3. [Initialization and constants](#initialization-and-constants)
4. [Classes and special members](#classes-and-special-members)
5. [Ownership and smart pointers](#ownership-and-smart-pointers)
6. [Lifetimes and dangling](#lifetimes-and-dangling)
7. [Containers](#containers)
8. [Overloads, ADL, namespaces](#overloads-adl-namespaces)
9. [Control flow and misc](#control-flow-and-misc)
10. [Tests](#tests)

---

## Strings

**#1 `string_view` is a non-owning view.** Take `absl::string_view` (or
`std::string_view`) by value for read-only string parameters. It accepts
`const char*`, `std::string`, and literals without copying. Never return one
from a function that built a temporary, and never store one in a member
unless the source is documented to outlive the object.

```cpp
// Bad: forces a std::string copy when caller has a literal or char*.
bool HasPrefix(const std::string& s, const std::string& prefix);
// Good.
bool HasPrefix(absl::string_view s, absl::string_view prefix);
```

**#3 String concatenation.** `a + b + c` creates a temporary per `+`. Use
`absl::StrCat(a, b, c)` for one allocation, `absl::StrAppend(&out, ...)` to
extend, and never `s = s + x` (use `absl::StrAppend(&s, x)` or `s += x`).

**#10 Splitting.** `absl::StrSplit(text, ',')` returns a lazy range
convertible to `std::vector<std::string>`, `std::vector<absl::string_view>`,
`std::pair`, `std::set`, etc. Use `absl::SkipEmpty()`,
`absl::ByAnyChar(", ")`, `absl::MaxSplits(':', 1)` as needed.

**#59 Joining.** `absl::StrJoin(container, ", ")`, with a formatter lambda
for non-string elements. Tuples join too.

**#64 Raw string literals.** `R"regex(\d+\.\d+)regex"` for regexes, JSON,
multiline text: no escaping mistakes.

**#124 `absl::StrFormat`.** Type-checked `printf` semantics. Prefer it over
`snprintf`/`std::stringstream`. `absl::StrFormat("%d items", n)`.

**#215 `AbslStringify`.** To make a type printable by `StrCat`, `StrFormat`
(`%v`), and logging, define
`template <typename Sink> friend void AbslStringify(Sink& sink, const T& t)`.

---

## Function signatures and return values

**#11 Return policy.** Return by value. Copy elision (guaranteed for prvalues
since C++17) and moves make `return big_object;` cheap. Do not return
`const T` (blocks moves), do not return `std::move(local)` (blocks NRVO).

**#176 Prefer return values to output parameters.** Out-params hide data
flow, prevent `const`, and force default construction. Return a struct if
you have several results.

```cpp
// Bad
bool Parse(absl::string_view s, Config* out);
// Good
absl::StatusOr<Config> Parse(absl::string_view s);
```

**#77 Temporaries, moves, copies.** `T t = MakeT();` is one construction.
`T t; t = MakeT();` is a default construction plus a move. Prefer declare-and-
initialize.

**#117 Copy elision and pass-by-value.** A "sink" parameter (one the function
will store or consume) should be taken by value and moved:
`explicit Widget(std::string name) : name_(std::move(name)) {}`. Callers with
an rvalue pay one move; callers with an lvalue pay one copy, which they would
have paid anyway.

**#234 Pass by value, by reference, or by pointer?** Value for sinks and
cheap types (`int`, `string_view`, `Span`); `const T&` for large read-only
inputs; `T*` or `T&` for in/out; `T*` (nullable) for optional non-owning
inputs. Pointer signals "may be modified or may be null"; reference signals
"non-null". Google style historically requires pointers for out-params
precisely for that visibility.

**#163 Passing `absl::optional` parameters.** Do not take
`const std::optional<T>&` as a parameter: callers with a `T` must construct
an optional. Take `const T*` (nullable) or overload.

**#188 Smart-pointer parameters.** Take `std::unique_ptr<T>` by value only to
take ownership. Take `std::shared_ptr<T>` by value only to *share*
ownership (store it). Otherwise take `T*` or `T&`: don't force callers into
a particular ownership model.

**#173 Option structs.** When a function takes more than three parameters, or
several of the same type, or many optional ones, bundle them:

```cpp
struct ConnectOptions {
  absl::Duration timeout = absl::Seconds(30);
  int max_retries = 3;
  bool use_tls = true;
};
absl::StatusOr<Connection> Connect(absl::string_view host,
                                   const ConnectOptions& options = {});
// Call site reads itself:
Connect(host, {.timeout = absl::Seconds(5), .use_tls = false});
```

**#172 Designated initializers.** Use `{.field = value}` for aggregates; it
documents the call site and catches field-order mistakes. Fields must be in
declaration order.

**#94 Call-site readability.** Avoid `bool` and adjacent same-type params.
`Rect(1, 2, 3, 4)` is unreadable; `Rect{.x = 1, .y = 2, .w = 3, .h = 4}` is
not. Use enums (`Mode::kAppend`) rather than `true`.

**#109 Meaningful `const` in declarations.** `void F(const int x);` in a
declaration means nothing to callers; leave top-level `const` off parameters
in declarations (it's fine in definitions).

**#141 Be explicit with `bool`.** `if (ptr)` and `if (!s.empty())` are idiomatic;
`if (n)` for an integer is not. Never `== true`.

**#120 Return values are untouchable.** Do not depend on the identity of a
returned object; do not write `F().member = x`.

---

## Initialization and constants

**#88 Initialization: `=`, `()`, `{}`.** Use `=` for literals and copies
(`int n = 5;`, `std::string s = "x";`, `auto p = std::make_unique<T>()`).
Use `{}` for aggregates, and for containers when listing elements
(`std::vector<int> v = {1, 2, 3};`). Use `()` for constructor calls where
`{}` would pick an `initializer_list` overload (`std::vector<int> v(3, 0);`).
Avoid empty `{}` on non-aggregates where `= T()` reads better.

**#146 Default vs value initialization.** `T t;` leaves scalars and
scalar members of aggregates uninitialized. `T t{};` or `T t = T();`
value-initializes. Give members default initializers in the class
(`int count_ = 0;`) so default construction is always safe.

**#140 Constants.** In headers: `inline constexpr int kMax = 10;` or
`constexpr absl::string_view kName = "x";` or `inline constexpr char kName[] =
"x";`. Never `const std::string` at namespace scope (non-trivial destructor,
static-init-order fiasco, ODR issues). For a non-constexpr constant, use a
function returning a `const T&` to a function-local static that is
intentionally leaked (`static const auto* const kTable = new Table{...};`).

**#168 `inline` variables.** C++17 `inline constexpr` lets you define
constants in headers with one address across TUs.

**#175 Literals.** `'` digit separators (`1'000'000`), `0b` binary, `u8`,
`1s`/`1ms` chrono literals in code that already uses chrono.

**#61 Default member initializers.** Prefer `int x_ = 0;` in the class body
over repeating it in every constructor's init list.

**#74 Delegating and inheriting constructors.** Use `Foo(int x) :
Foo(x, kDefault) {}` instead of duplicating init logic; `using Base::Base;`
to inherit constructors when the derived class adds no state.

---

## Classes and special members

**#131 `= default` and the rule of zero.** Prefer no user-declared special
members. If you need a custom destructor, you almost certainly need
copy/move handled too (rule of five); usually the fix is a member that does
the job (`std::unique_ptr`, an RAII wrapper) so you're back at zero.

**#143 Operators.** Overload only when the meaning is obvious and symmetric
(`==`, `<`, `+` for numeric-like types). Define `==` as a friend non-member
(or `= default` in C++20). Never overload `&&`, `||`, `,`.

**#152 `AbslHashValue`.** To use a type as a key in `absl::flat_hash_map`
define `template <typename H> friend H AbslHashValue(H h, const T& t) {
return H::combine(std::move(h), t.a, t.b); }` and `operator==`.

**#177 Assignability vs member types.** A class with a `const` or reference
member cannot be assigned. Prefer non-const members with private access.

**#142 Multi-parameter constructors and `explicit`.** Constructors that are
not conversions should be `explicit` even with several parameters, to stop
`Foo f = {1, 2};` silently converting. Exception: deliberate aggregate-like
types.

**#42 Factory functions over `Init()` methods.** Two-phase initialization
allows an object to exist in an invalid state. Provide
`static absl::StatusOr<Foo> Create(args)` and a private constructor.

**#134 `make_unique` and private constructors.** `std::make_unique` cannot
call a private constructor. Use `absl::WrapUnique(new Foo(...))` inside the
factory, or a private tag type.

**#198 Tag types.** To distinguish overloads or unlock private constructors,
pass an empty `struct PrivateTag {}` rather than a `bool` or magic value.

**#186 Prefer functions in the unnamed namespace** in `.cc` files over
private static member functions; they don't need the class's header to
change and don't get access they shouldn't need.

**#99 Non-member interface etiquette.** Non-member functions that are part of
a type's interface (`operator<<`, `AbslHashValue`, `swap`) go in the same
namespace and the same header as the type.

---

## Ownership and smart pointers

**#126 `make_unique` is the new `new`.** Never write a bare `new`; use
`std::make_unique<T>(...)` (exception safe, ownership obvious). `new`
appears only inside `absl::WrapUnique` or allocator code.

**#187 `unique_ptr` must be moved.** Returning a local `unique_ptr` is a
move automatically; passing one to a function requires an explicit
`std::move`, which is good, because it makes the ownership transfer visible.

**#123 `absl::optional` and `std::unique_ptr`.** For "may not have a value",
use `std::optional<T>` if `T` is cheap and complete; use `std::unique_ptr<T>`
if `T` is polymorphic, expensive to move, or incomplete.

**#149 Object lifetimes vs `= delete`.** Deleting a function overload
(`void F(std::string&&) = delete;`) to prevent binding a temporary is a
blunt tool; prefer types that don't dangle in the first place.

**#5 Disappearing act.** `absl::string_view v = SomeFunctionReturningString();`
dangles at the end of the full expression. Bind to a `std::string` first.

---

## Lifetimes and dangling

**#101 Return values, references, lifetimes.** A `const T&` returned from an
accessor is valid only as long as the owning object; `const auto& x =
obj.field();` is fine, `const auto& x = MakeObj().field();` dangles.

**#107 Reference lifetime extension.** `const T& r = MakeT();` extends the
temporary's life. `const T& r = MakeT().member;` does too (since it's a
subobject), but `const T& r = MakeT().Getter();` does **not**. Don't rely on
this; declare a value.

**#180 Avoiding dangling references.** Watch: `string_view` from a temporary
string; `Span` from a temporary vector; lambda capturing `[&]` outliving its
scope; returning a reference to a local; a `const T&` parameter stored as a
member; range-for over a temporary's subobject (`for (auto& x :
MakeObj().items())` dangles before C++23).

**#231 Here be dangling.** `std::vector::back()` reference invalidated by
`push_back`; `absl::flat_hash_map` references invalidated by any insert;
`std::string::c_str()` invalidated by any mutation.

---

## Containers

**#136 Unordered containers.** Prefer `absl::flat_hash_map`/`set` for
performance (open addressing, cache friendly). Use `absl::node_hash_map` only
when you need pointer stability of values. Use `absl::btree_map` for ordered
iteration or range queries. Prefer `std::vector` for small collections:
linear scans of 8 elements beat any hash.

**#144 Heterogeneous lookup.** `absl::flat_hash_map<std::string, V>` supports
`Find(absl::string_view)` without constructing a `std::string`. Use it.
`std::map` needs `std::less<>` as the comparator for this.

**#112 `emplace` vs `push_back`.** `push_back(T{...})` and `emplace_back(...)`
are equivalent after elision; prefer `push_back` with an explicit
constructor when it's clearer which constructor runs, `emplace_back` for
in-place construction of non-movable types or to avoid a temporary.

**#65 Putting things in their place.** `std::map::try_emplace(key, args...)`
avoids constructing the value if the key exists; `insert_or_assign` is
explicit about overwrite.

**#93 `absl::Span`.** Take `absl::Span<const T>` for read-only sequence
parameters (accepts `std::vector`, arrays, `std::array`, initializer lists);
`absl::Span<T>` to mutate elements. Never store a `Span` without a lifetime
guarantee.

**#224 Avoid `vector.at()`.** It throws `std::out_of_range`, which is
neither a useful error to callers nor a good bounds check. Use `operator[]`
with a hardened build (`ABSL_HARDENED`, libc++ hardening,
`_GLIBCXX_ASSERTIONS`) plus an explicit check where the index comes from
untrusted input.

**#227 Empty containers.** `v.front()`, `v.back()`, `*v.begin()`,
`s[0]` on an empty container is UB. Check `empty()` first.

**#166 When a copy is not a copy.** `auto x = f();` never copies (guaranteed
elision). `auto x = y;` copies. `for (auto x : container)` copies each
element; use `const auto&` unless you need a mutable copy.

---

## Overloads, ADL, namespaces

**#148 Overload sets.** An overload set should be one operation with the
same semantics for every overload. If `Process(int)` and
`Process(std::string)` do different things, they need different names.

**#229 Ranking overloads.** Prefer a single template or a `string_view`
overload to a pile of `const char*`/`std::string`/`string_view` overloads.

**#49 ADL.** Unqualified calls to `swap(a, b)`, `begin(c)`, `AbslHashValue`,
`operator<<` find functions in the argument's namespace. Use it for
customization points; avoid it by qualifying (`std::sort`) for everything
else.

**#119 `using` declarations and namespace aliases.** Only inside `.cc` files
or function scope; never in headers at namespace scope.

**#153 Using-directives are a menace.** `using namespace foo;` changes name
lookup for everything that follows and breaks silently when names are added.
Never in headers, and avoid in `.cc` files.

**#130 Namespace naming.** Short, lowercase, project-unique
(`namespace myproj::net`). Nest with `::` (C++17). Don't reopen `std`.

---

## Control flow and misc

**#86 Enumerating with `enum class`.** Scoped enums don't implicitly convert
to int and don't pollute the enclosing scope. Give them an underlying type
if they are stored or serialized.

**#147 Exhaustive `switch`.** Switch over an `enum class` without `default`
so the compiler warns (`-Wswitch`) when a new enumerator appears; handle
"unexpected value" after the switch with `CHECK`/`LOG(FATAL)` or a
`Status`.

**#165 `if`/`switch` with initializers.** `if (auto it = m.find(k); it !=
m.end())` scopes the variable to the branch. Use it.

**#171 Avoid sentinel values.** `-1`, `""`, `nullptr` as "no value" are
bugs waiting to happen. Use `std::optional`, `StatusOr`, or an enum.

**#108 Avoid `std::bind`.** Lambdas are clearer, faster, and don't silently
copy or ignore extra arguments.

**#161 Good locals and bad locals.** A local that exists only to be passed
once, or that outlives its usefulness, hurts readability. Inline or scope.
A named local that explains a complex expression helps.

**#45 Avoid flags, especially in library code.** Global flags are hidden
inputs. Pass configuration explicitly through options structs.

**#55 Name counting and `unique_ptr`.** If a value has more than one name
that could be the "owner", ownership is unclear. Move so that at any point
one name owns.

**#181 Accessing `StatusOr<T>`.** Check `ok()` (or use `ASSIGN_OR_RETURN`),
then `*s` / `s->member`. `s.value()` also checks but produces a poor error
on failure; prefer the explicit check.

**#197 Reader locks should be rare.** `absl::ReaderMutexLock` is often
slower than an exclusive lock under contention because of cache-line
bouncing. Use it only for long, read-heavy critical sections, and measure.

**#242 Dead code.** Delete unused functions, parameters, includes and
`#if 0` blocks; version control remembers them.

---

## Tests

**#122 Test fixtures, clarity, sharing.** Fixtures should hold only setup that
every test uses. Helper functions that return values beat member state.
Don't hide the assertion in a helper; if you must, use `SCOPED_TRACE` and
`ASSERT_NO_FATAL_FAILURE`.

**#135 Test the contract, not the implementation.** Name tests by behavior;
avoid asserting call sequences on mocks unless the sequence *is* the
contract.

**GoogleTest matcher rules.** `EXPECT_THAT(status, IsOk())`,
`EXPECT_THAT(result, IsOkAndHolds(Eq(3)))`, `EXPECT_THAT(v, ElementsAre(1,
2))`, `EXPECT_THAT(s, HasSubstr("x"))`. Prefer `EXPECT_*` for all but
preconditions of later assertions, which use `ASSERT_*`.
