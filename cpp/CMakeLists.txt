# Plane World C++ port (docs/PORT_PLAN.md). Targets:
#   pwcore  - static lib, C++20, no Qt: math, determinism, CPU feature dispatch, JSON, self-tests
#   pwgpu   - GPU backend abstraction: Metal (Objective-C++) on Apple, Direct3D 12 on Windows; Slang shaders
#   pwapp   - Qt 6 Quick application (native Qt Quick Controls style, embedded GPU viewport)
#   pwtests - doctest unit + parity tests
#   pwcli   - headless --selftest / --train / --bench / --gpu-smoke
cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "")
project(PlaneWorld VERSION 0.1.0 LANGUAGES C CXX)
if(APPLE)
  enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(PW_BUILD_APP "Build the Qt 6 Quick app (pwapp)" ON)
option(PW_BUILD_TESTS "Build pwtests" ON)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(PWCompilerFlags)
include(PWSlang)

add_subdirectory(src/core)
add_subdirectory(shaders)
add_subdirectory(src/gpu)
add_subdirectory(src/cli)
if(PW_BUILD_APP)
  add_subdirectory(src/app)
endif()
if(PW_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
