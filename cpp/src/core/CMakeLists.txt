add_library(pwcore STATIC
  src/cpu.cpp
  src/reduce.cpp
  src/json.cpp
  src/aero.cpp
  src/parity.cpp
  src/selftest.cpp
  src/core_selftests.cpp
  # P1a: math / jobs / atmosphere / craft simulation
  src/atmosphere.cpp
  src/jobs.cpp
  src/sim/craft_spec.cpp
  src/sim/fidelity.cpp
  src/sim/panel_aero.cpp
  src/sim/craft_sim.cpp
  src/sim/fast_gaps.cpp
  src/sim/sensors.cpp
)
target_include_directories(pwcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(pwcore PUBLIC pw_flags)
target_compile_definitions(pwcore PUBLIC PW_VERSION="${PROJECT_VERSION}"
  PW_DEFAULT_PARITY_DIR="${PROJECT_SOURCE_DIR}/tests/parity")
include(${CMAKE_CURRENT_SOURCE_DIR}/craft_world.cmake)
