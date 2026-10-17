add_library(pwcore STATIC
  src/cpu.cpp
  src/reduce.cpp
  src/json.cpp
  src/aero.cpp
  src/parity.cpp
  src/selftest.cpp
  src/core_selftests.cpp
  # P1a: math / jobs / atmosphere / craft simulation
  src/math.cpp
  src/atmosphere.cpp
  src/jobs.cpp
  src/sim/craft_spec.cpp
  src/sim/craft_spec_doc.cpp
  src/sim/fidelity.cpp
  src/sim/panel_aero.cpp
  src/sim/craft_sim.cpp
  src/sim/fast_gaps.cpp
  src/sim/sensors.cpp
  src/sim/physics_selftests.cpp
  src/simd_scalar.cpp
  src/simd_neon.cpp
  src/simd_avx2.cpp
  src/simd_avx512.cpp
)
target_include_directories(pwcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
# P1a: each SIMD kernel TU is compiled for its own ISA (runtime dispatch picks one; see pw/simd_kernels.h).
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$" OR CMAKE_OSX_ARCHITECTURES MATCHES "x86_64")
  if(MSVC)
    set_source_files_properties(src/simd_avx2.cpp PROPERTIES COMPILE_OPTIONS "/arch:AVX2")
    set_source_files_properties(src/simd_avx512.cpp PROPERTIES COMPILE_OPTIONS "/arch:AVX512")
  else()
    set_source_files_properties(src/simd_avx2.cpp PROPERTIES COMPILE_OPTIONS "-mavx2;-mfma")
    set_source_files_properties(src/simd_avx512.cpp PROPERTIES COMPILE_OPTIONS "-mavx512f;-mavx512dq;-mfma")
  endif()
endif()
target_link_libraries(pwcore PUBLIC pw_flags)
target_compile_definitions(pwcore PUBLIC PW_VERSION="${PROJECT_VERSION}"
  PW_DEFAULT_PARITY_DIR="${PROJECT_SOURCE_DIR}/tests/parity")
include(${CMAKE_CURRENT_SOURCE_DIR}/craft_world.cmake)
include(${CMAKE_CURRENT_SOURCE_DIR}/script.cmake)
