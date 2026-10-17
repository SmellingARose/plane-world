# Slang sources -> MSL (Apple) / DXIL (Windows), embedded into pw_shaders.
add_library(pw_shaders STATIC)
target_include_directories(pw_shaders PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
pw_add_slang_shaders(pw_shaders
  FILES viewport.slang gputest.slang scene.slang atmosphere.slang taa.slang bloom.slang tonemap.slang
        env/terrain.slang env/water.slang env/vegetation.slang env/grass.slang env/fluidsurface.slang   # P3b: drawn by pwenv_render
  DEPENDS common.slang)
