include(FetchContent)
FetchContent_Declare(doctest
  URL https://github.com/doctest/doctest/archive/refs/tags/v2.4.11.tar.gz
  URL_HASH SHA256=632ed2c05a7f53fa961381497bf8069093f0d6628c5f26286161fbd32a560186
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR _none_)   # header-only use: don't configure doctest's own CMake project
FetchContent_MakeAvailable(doctest)

add_executable(pwtests main.cpp test_core.cpp test_parity.cpp test_gpu.cpp alloc_counter.cpp
  test_math.cpp test_sim.cpp test_physics.cpp test_script.cpp)
target_include_directories(pwtests PRIVATE ${doctest_SOURCE_DIR})
target_link_libraries(pwtests PRIVATE pwcore pwgpu)
add_test(NAME pwtests COMMAND pwtests)
add_test(NAME pwcli-selftest COMMAND pwcli --selftest all)
target_sources(pwtests PRIVATE test_craft_world.cpp)   # P1b: craft / world / collision
target_sources(pwtests PRIVATE test_evolution.cpp)   # P2a: evolution
target_sources(pwtests PRIVATE test_render.cpp)   # P3a: renderer
target_link_libraries(pwtests PRIVATE pwrender)
target_compile_definitions(pwtests PRIVATE PW_RENDER_REF_DIR="${PROJECT_SOURCE_DIR}/tests/render_ref")
target_sources(pwtests PRIVATE test_env.cpp)   # P3b: terrain / water / vegetation
target_link_libraries(pwtests PRIVATE pwenv pwenv_render)
