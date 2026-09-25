# Defines `project_sanitizers` from the PROJECT_SANITIZER cache variable.
#   ""                   no sanitizer
#   "address,undefined"  ASan + UBSan (default test configuration)
#   "thread"             TSan
#   "memory"             MSan (clang only; needs an MSan-instrumented libc++)

add_library(project_sanitizers INTERFACE)

if(NOT PROJECT_SANITIZER)
  return()
endif()

if(MSVC)
  if(PROJECT_SANITIZER MATCHES "address")
    target_compile_options(project_sanitizers INTERFACE /fsanitize=address)
  else()
    message(WARNING "MSVC supports only AddressSanitizer; ignoring '${PROJECT_SANITIZER}'")
  endif()
  return()
endif()

set(_san_flags -fsanitize=${PROJECT_SANITIZER} -fno-omit-frame-pointer -fno-optimize-sibling-calls)

if(PROJECT_SANITIZER MATCHES "undefined")
  list(APPEND _san_flags
    -fno-sanitize-recover=all           # first UB report is fatal
    -fsanitize=float-divide-by-zero)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    list(APPEND _san_flags
      -fsanitize=local-bounds
      -fsanitize=implicit-conversion    # noisy on legacy code; remove if needed
      -fsanitize=nullability)
  else()
    list(APPEND _san_flags -fsanitize=bounds-strict)
  endif()
endif()

if(PROJECT_SANITIZER MATCHES "memory")
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "MemorySanitizer requires clang")
  endif()
  list(APPEND _san_flags -fsanitize-memory-track-origins=2)
  # Point at an MSan-instrumented libc++ (built with -DLLVM_USE_SANITIZER=MemoryWithOrigins):
  #   -DPROJECT_MSAN_LIBCXX=/path/to/libcxx-msan
  if(PROJECT_MSAN_LIBCXX)
    target_compile_options(project_sanitizers INTERFACE -stdlib=libc++ -I${PROJECT_MSAN_LIBCXX}/include/c++/v1)
    target_link_options(project_sanitizers INTERFACE -stdlib=libc++ -L${PROJECT_MSAN_LIBCXX}/lib -Wl,-rpath,${PROJECT_MSAN_LIBCXX}/lib)
  endif()
endif()

target_compile_options(project_sanitizers INTERFACE ${_san_flags})
target_link_options(project_sanitizers INTERFACE -fsanitize=${PROJECT_SANITIZER})

# Sanitized builds should not use LTO or -O3 (slower to build, harder to read reports).
set(PROJECT_ENABLE_LTO OFF CACHE BOOL "" FORCE)
