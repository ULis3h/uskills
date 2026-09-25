# Top-level CMake template. Replace `project` with the real project name
# (also in CMakePresets.json and .clang-tidy). Requires CMake >= 3.25.
cmake_minimum_required(VERSION 3.25)

project(project VERSION 0.1.0 LANGUAGES CXX)

# ---- Global settings -------------------------------------------------------
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---- Options ---------------------------------------------------------------
option(PROJECT_BUILD_TESTS "Build unit tests" ON)
option(PROJECT_BUILD_BENCHMARKS "Build benchmarks" ON)
option(PROJECT_BUILD_FUZZERS "Build libFuzzer targets (clang only)" OFF)
option(PROJECT_WARNINGS_AS_ERRORS "Treat warnings as errors" ON)
option(PROJECT_ENABLE_LTO "Enable link-time optimization in Release" ON)
option(PROJECT_ENABLE_HARDENING "Enable hardened stdlib and runtime checks" ON)
set(PROJECT_SANITIZER "" CACHE STRING
    "Sanitizer set: '', 'address,undefined', 'thread', 'memory'")

# ---- Build speed -----------------------------------------------------------
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  find_program(LLD_PROGRAM ld.lld)
  if(LLD_PROGRAM)
    add_link_options(-fuse-ld=lld)
  endif()
endif()

# ---- Interface targets carrying flags -------------------------------------
include(Warnings)     # defines project_warnings
include(Sanitizers)   # defines project_sanitizers from PROJECT_SANITIZER
include(Hardening)    # defines project_hardening

add_library(project_options INTERFACE)
target_compile_options(project_options INTERFACE -fno-omit-frame-pointer)
target_link_libraries(project_options INTERFACE project_sanitizers project_hardening)

if(PROJECT_ENABLE_LTO AND CMAKE_BUILD_TYPE STREQUAL "Release" AND NOT PROJECT_SANITIZER)
  include(CheckIPOSupported)
  check_ipo_supported(RESULT ipo_ok OUTPUT ipo_msg)
  if(ipo_ok)
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
  else()
    message(STATUS "LTO not supported: ${ipo_msg}")
  endif()
endif()

# ---- Dependencies ----------------------------------------------------------
include(FetchContent)
set(FETCHCONTENT_QUIET OFF)

set(ABSL_PROPAGATE_CXX_STD ON)
set(ABSL_ENABLE_INSTALL OFF)
set(ABSL_BUILD_TESTING OFF)
FetchContent_Declare(abseil
  GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
  GIT_TAG        20250512.0   # pin: update deliberately
  GIT_SHALLOW    TRUE)

set(BUILD_GMOCK ON)
set(INSTALL_GTEST OFF)
FetchContent_Declare(googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.17.0
  GIT_SHALLOW    TRUE)

set(BENCHMARK_ENABLE_TESTING OFF)
set(BENCHMARK_ENABLE_INSTALL OFF)
set(BENCHMARK_ENABLE_GTEST_TESTS OFF)
FetchContent_Declare(benchmark
  GIT_REPOSITORY https://github.com/google/benchmark.git
  GIT_TAG        v1.9.4
  GIT_SHALLOW    TRUE)

FetchContent_MakeAvailable(abseil)
if(PROJECT_BUILD_TESTS)
  FetchContent_MakeAvailable(googletest)
endif()
if(PROJECT_BUILD_BENCHMARKS)
  FetchContent_MakeAvailable(benchmark)
endif()

# ---- Sources ---------------------------------------------------------------
add_subdirectory(src/project)

# ---- Tests -----------------------------------------------------------------
if(PROJECT_BUILD_TESTS)
  enable_testing()
  include(GoogleTest)
  file(GLOB_RECURSE PROJECT_TEST_SOURCES CONFIGURE_DEPENDS src/*_test.cc)
  if(PROJECT_TEST_SOURCES)
    add_executable(project_tests ${PROJECT_TEST_SOURCES})
    target_link_libraries(project_tests PRIVATE
      project_all            # umbrella library defined in src/project/CMakeLists.txt
      GTest::gtest GTest::gmock GTest::gtest_main
      project_warnings project_options)
    gtest_discover_tests(project_tests DISCOVERY_MODE PRE_TEST
      PROPERTIES ENVIRONMENT "ASAN_OPTIONS=detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_odr_violation=2;UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1;TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1")
  endif()
endif()

# ---- Benchmarks ------------------------------------------------------------
if(PROJECT_BUILD_BENCHMARKS)
  file(GLOB_RECURSE PROJECT_BENCH_SOURCES CONFIGURE_DEPENDS src/*_bench.cc)
  if(PROJECT_BENCH_SOURCES)
    add_executable(project_benches ${PROJECT_BENCH_SOURCES})
    target_link_libraries(project_benches PRIVATE
      project_all benchmark::benchmark benchmark::benchmark_main
      project_warnings project_options)
    add_custom_target(bench
      COMMAND project_benches --benchmark_repetitions=5 --benchmark_report_aggregates_only=true
      USES_TERMINAL)
  endif()
endif()

# ---- Fuzzers ---------------------------------------------------------------
if(PROJECT_BUILD_FUZZERS)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "Fuzzers require clang")
  endif()
  file(GLOB PROJECT_FUZZ_SOURCES CONFIGURE_DEPENDS fuzz/*_fuzzer.cc)
  foreach(src ${PROJECT_FUZZ_SOURCES})
    get_filename_component(name ${src} NAME_WE)
    add_executable(${name} ${src})
    target_link_libraries(${name} PRIVATE project_all project_warnings project_options)
    target_compile_options(${name} PRIVATE -fsanitize=fuzzer)
    target_link_options(${name} PRIVATE -fsanitize=fuzzer)
  endforeach()
endif()

# ---- Formatting and static analysis targets -------------------------------
file(GLOB_RECURSE PROJECT_ALL_CXX_FILES CONFIGURE_DEPENDS
  src/*.cc src/*.h fuzz/*.cc)
find_program(CLANG_FORMAT clang-format)
if(CLANG_FORMAT)
  add_custom_target(format COMMAND ${CLANG_FORMAT} -i ${PROJECT_ALL_CXX_FILES})
  add_custom_target(format-check
    COMMAND ${CLANG_FORMAT} --dry-run --Werror ${PROJECT_ALL_CXX_FILES})
endif()
find_program(RUN_CLANG_TIDY run-clang-tidy)
if(RUN_CLANG_TIDY)
  add_custom_target(tidy
    COMMAND ${RUN_CLANG_TIDY} -p ${CMAKE_BINARY_DIR} -quiet
            "^${CMAKE_SOURCE_DIR}/src/.*"
    USES_TERMINAL)
endif()
