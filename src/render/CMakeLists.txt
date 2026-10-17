# pwrender: renderer core on pwgpu (frame graph, atmosphere LUTs, cascaded shadows, PBR, TAA, bloom, ACES,
# debug lines, mesh / craft part rendering). Platform independent C++ (the GPU API lives in pwgpu).
add_library(pwrender STATIC src/framegraph.cpp src/renderer.cpp src/craft_renderable.cpp src/render_selftests.cpp)
target_include_directories(pwrender PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(pwrender PUBLIC pwcore pwgpu pw_flags)
