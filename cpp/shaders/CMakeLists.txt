# Slang sources -> MSL (Apple) / DXIL (Windows), embedded into pw_shaders.
add_library(pw_shaders STATIC)
target_include_directories(pw_shaders PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
pw_add_slang_shaders(pw_shaders FILES viewport.slang)
