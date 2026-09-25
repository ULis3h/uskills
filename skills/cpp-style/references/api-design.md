# Designing a C++ API the Abseil way

Use this when creating a new class, a function family, or a library
boundary. The goal is an interface that is hard to misuse, cheap to call,
and stable under change.

## Process

1. **Write the call sites first.** Draft three realistic uses of the API in
   a scratch buffer before writing the header. If the calls need comments to
   be understood, change the API, not the comments.
2. **Decide the ownership story** for every object crossing the boundary.
   Who allocates, who frees, who may outlive whom. Encode it in types
   (`unique_ptr` for transfer, `T*`/`T&` for borrow, value for copy).
3. **Decide the error story.** Which calls can fail, and whether failure is
   a programmer error (precondition: `CHECK`/`DCHECK`, document it) or a
   runtime condition (`absl::Status`).
4. **Decide the thread-safety story** and write it in the class comment:
   "thread-compatible" (const methods may run concurrently), "thread-safe",
   or "thread-hostile". Default is thread-compatible.
5. **Minimize the surface.** Every public member is a promise you keep
   forever. Prefer free functions in the namespace over member functions
   when they don't need private state; prefer one general function over
   many overloads.
6. Only now write the header, with a doc comment on every public symbol.

## Header template

```cpp
// Copyright ...
#ifndef MYPROJ_NET_CONNECTION_H_
#define MYPROJ_NET_CONNECTION_H_

#include <memory>
#include <string>

#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/time/time.h"

namespace myproj::net {

struct ConnectionOptions {
  absl::Duration connect_timeout = absl::Seconds(10);
  absl::Duration read_timeout = absl::Seconds(30);
  bool use_tls = true;
};

// A single client connection to a remote host.
//
// Thread-compatible: concurrent const calls are safe; concurrent mutation
// requires external synchronization.
//
// Ownership: the Connection owns its socket and closes it on destruction.
class Connection {
 public:
  // Opens a connection to `host:port`. Returns an error status if the host
  // cannot be resolved or the connect times out.
  static absl::StatusOr<std::unique_ptr<Connection>> Open(
      absl::string_view host, int port, const ConnectionOptions& options = {});

  Connection(const Connection&) = delete;
  Connection& operator=(const Connection&) = delete;
  ~Connection();

  // Writes all of `data`. Returns kDeadlineExceeded if `read_timeout`
  // elapses before the write completes.
  absl::Status Write(absl::string_view data);

  // Reads up to `buffer.size()` bytes into `buffer`. Returns the number of
  // bytes read; 0 means the peer closed the connection.
  absl::StatusOr<size_t> Read(absl::Span<char> buffer);

  absl::string_view host() const { return host_; }

 private:
  Connection(int fd, std::string host);

  int fd_;
  std::string host_;
};

}  // namespace myproj::net

#endif  // MYPROJ_NET_CONNECTION_H_
```

Things to notice: factory over throwing constructor; option struct with
defaults; view/span parameters; every method documents its failure modes;
non-copyable resource handle with explicit deletions; private constructor so
the invariant "an open Connection has a valid fd" holds.

## Parameter and return checklist

- Does every `string_view`/`Span`/reference parameter have a lifetime shorter
  than the call? If it will be stored, take it by value (`std::string`,
  `std::vector<T>`) and move.
- Are there two adjacent parameters of the same type? Consider a struct.
- Is there a `bool` parameter? Replace with `enum class`.
- Can this function be `const`? `noexcept`? `constexpr`? `[[nodiscard]]`?
- Does it return a raw pointer? Document nullability and non-ownership,
  or return a reference / `unique_ptr` / `optional` instead.
- Does it return a `const std::string&` to a member? Fine for accessors;
  consider `absl::string_view` if callers only read, so the implementation
  can change.
- Does it return a `std::vector` that callers usually iterate once? Consider
  taking an `absl::FunctionRef` callback or returning a range/`Span` into
  storage the object owns.

## Class checklist

- Invariants written down in the class comment.
- Members in a sensible order; all have default member initializers.
- Special members: rule of zero, or all five explicit.
- Polymorphic base: virtual destructor, `override` everywhere, no public
  virtuals except the destructor if using NVI (public non-virtual calls
  private virtual).
- No `Init()`; a constructed object is valid.
- No getters returning non-const references to internals (that's just a
  public member with extra steps). If callers need to mutate, provide an
  operation with a name.
- Comparison: `friend bool operator==(const T&, const T&) = default;` where
  meaningful; `AbslHashValue` if used as a hash key.
- Printing: `AbslStringify` if it will be logged.

## Evolving an API without breaking callers

- Add parameters via the option struct, not via new overloads.
- Add enumerators at the end and handle them exhaustively.
- Deprecate with `[[deprecated("use Foo::Bar")]]` and keep both for a
  release cycle.
- Never change the meaning of an existing parameter; add a new function.
- Keep ABI-affecting details (member layout, inline functions) out of
  headers that are consumed across a stable boundary; use Pimpl there.
