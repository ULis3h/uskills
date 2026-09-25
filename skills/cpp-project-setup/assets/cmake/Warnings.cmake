# Defines the `project_warnings` interface target. Link it PRIVATE into every
# first-party target; never into third-party code.

add_library(project_warnings INTERFACE)

set(_common_warnings
  -Wall
  -Wextra
  -Wpedantic
  -Wshadow
  -Wconversion
  -Wsign-conversion
  -Wold-style-cast
  -Wcast-align
  -Wcast-qual
  -Wnon-virtual-dtor
  -Woverloaded-virtual
  -Wnull-dereference
  -Wdouble-promotion
  -Wformat=2
  -Wimplicit-fallthrough
  -Wmisleading-indentation
  -Wunused
  -Wundef
)

set(_clang_warnings
  ${_common_warnings}
  -Wthread-safety          # honors ABSL_GUARDED_BY etc.
  -Wextra-semi
  -Wcomma
  -Wdangling
  -Wshorten-64-to-32
  -Wimplicit-int-conversion
  -Wunreachable-code
  -Wloop-analysis
  -Wshadow-all
  -Wsuggest-override
)

set(_gcc_warnings
  ${_common_warnings}
  -Wduplicated-cond
  -Wduplicated-branches
  -Wlogical-op
  -Wuseless-cast
  -Wsuggest-override
  -Wno-missing-field-initializers   # designated initializers with defaults trip this
)

set(_msvc_warnings
  /W4
  /permissive-
  /w14242 /w14254 /w14263 /w14265 /w14287 /we4289 /w14296 /w14311
  /w14545 /w14546 /w14547 /w14549 /w14555 /w14619 /w14640 /w14826
  /w14905 /w14906 /w14928
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  set(_warnings ${_clang_warnings})
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  set(_warnings ${_gcc_warnings})
elseif(MSVC)
  set(_warnings ${_msvc_warnings})
endif()

if(PROJECT_WARNINGS_AS_ERRORS)
  if(MSVC)
    list(APPEND _warnings /WX)
  else()
    list(APPEND _warnings -Werror)
  endif()
endif()

target_compile_options(project_warnings INTERFACE ${_warnings})
