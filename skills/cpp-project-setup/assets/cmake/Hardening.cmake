# Defines `project_hardening`: cheap runtime checks that stay on in production,
# plus stronger ones in Debug and sanitizer builds. Controlled by
# PROJECT_ENABLE_HARDENING.

add_library(project_hardening INTERFACE)

if(NOT PROJECT_ENABLE_HARDENING OR MSVC)
  return()
endif()

# Abseil: bounds checks in Span, optional, StatusOr, InlinedVector...
target_compile_definitions(project_hardening INTERFACE ABSL_HARDENED=1)

# Standard library hardening.
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND CMAKE_CXX_FLAGS MATCHES "libc\\+\\+")
  # libc++: FAST in release, DEBUG for Debug and sanitizer builds.
  target_compile_definitions(project_hardening INTERFACE
    $<IF:$<OR:$<CONFIG:Debug>,$<BOOL:${PROJECT_SANITIZER}>>,
        _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG,
        _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST>)
else()
  # libstdc++: _GLIBCXX_ASSERTIONS is ABI-safe; _GLIBCXX_DEBUG is not (whole-program only).
  target_compile_definitions(project_hardening INTERFACE _GLIBCXX_ASSERTIONS)
endif()

# Compiler/runtime hardening for non-sanitized optimized builds.
if(NOT PROJECT_SANITIZER)
  target_compile_options(project_hardening INTERFACE
    $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=3>
    -fstack-protector-strong
    -fstack-clash-protection
    -ftrivial-auto-var-init=zero)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    target_compile_options(project_hardening INTERFACE -fcf-protection=full)
  endif()
  target_link_options(project_hardening INTERFACE
    -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)
endif()
