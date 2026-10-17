# pwenv (P3b): terrain, water and vegetation on top of pwcore (world / physics interfaces) and pwgpu (compute).
include(FetchContent)
FetchContent_Declare(pw_zlib
  URL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
  URL_HASH SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR _none_)   # compiled below as a plain static library (zlib's own CMake installs/renames files)
FetchContent_Declare(pw_stb
  URL https://raw.githubusercontent.com/nothings/stb/f58f558c120e9b32c217290b80bad1a0729fbb2c/stb_image.h
  URL_HASH SHA256=594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3
  DOWNLOAD_NO_EXTRACT TRUE)
FetchContent_MakeAvailable(pw_zlib pw_stb)

add_library(pw_zlib STATIC)
foreach(f adler32 compress crc32 deflate infback inffast inflate inftrees trees uncompr zutil)
  target_sources(pw_zlib PRIVATE ${pw_zlib_SOURCE_DIR}/${f}.c)
endforeach()
target_include_directories(pw_zlib PUBLIC ${pw_zlib_SOURCE_DIR})
if(MSVC)
  target_compile_definitions(pw_zlib PRIVATE _CRT_SECURE_NO_DEPRECATE _CRT_NONSTDC_NO_DEPRECATE)
  target_compile_options(pw_zlib PRIVATE /W0)
else()
  target_compile_definitions(pw_zlib PRIVATE HAVE_UNISTD_H)
  target_compile_options(pw_zlib PRIVATE -w)
endif()

add_library(pwenv STATIC
  src/codec.cpp
  src/terrain.cpp
  src/dem.cpp
  src/erosion.cpp
  src/lod.cpp
  src/ocean.cpp
  src/hydro.cpp
  src/water.cpp
  src/fluid.cpp
  src/trees.cpp
  src/vegetation.cpp
  src/env_selftests.cpp
  src/terrain_selftests.cpp
  src/water_selftests.cpp
  src/vegetation_selftests.cpp)
target_include_directories(pwenv PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} PRIVATE ${pw_stb_SOURCE_DIR} ${PROJECT_SOURCE_DIR}/shaders/include)
target_link_libraries(pwenv PUBLIC pwcore pwgpu PRIVATE pw_zlib)
if(APPLE)
  target_sources(pwenv PRIVATE src/http_apple.mm)
  set_source_files_properties(src/http_apple.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(pwenv PUBLIC "-framework Foundation")
elseif(WIN32)
  target_sources(pwenv PRIVATE src/http_win.cpp)
  target_link_libraries(pwenv PUBLIC winhttp)
endif()

# Slang: compute kernels (erosion, ocean, fluid) and the render shaders (terrain CDLOD, water surface, trees /
# impostors / grass). Render entry points are compiled and validated here; drawing them is the renderer's job (P3a).
pw_add_slang_library(pwenv NAMESPACE pw::env_shaders HEADER pw/env_shaders.h
  INCLUDES ${PROJECT_SOURCE_DIR}/shaders/env
  SHADERS
    ${PROJECT_SOURCE_DIR}/shaders/env/erosion.slang
    ${PROJECT_SOURCE_DIR}/shaders/env/ocean.slang
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang
    ${PROJECT_SOURCE_DIR}/shaders/env/terrain.slang
    ${PROJECT_SOURCE_DIR}/shaders/env/water.slang
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang
  ENTRIES
    ${PROJECT_SOURCE_DIR}/shaders/env/erosion.slang:erodeRainFlux:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/erosion.slang:erodeWaterSediment:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/erosion.slang:erodeAdvect:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/erosion.slang:erodeThermal:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/ocean.slang:oceanSpecRowFFT:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/ocean.slang:oceanColFFTFinalize:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidClear:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidP2G:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidNormalize:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidClassify:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidForces:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidDivergence:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidPressure:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidProject:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/fluid.slang:fluidG2P:compute
    ${PROJECT_SOURCE_DIR}/shaders/env/terrain.slang:terrainVS:vertex
    ${PROJECT_SOURCE_DIR}/shaders/env/terrain.slang:terrainPS:fragment
    ${PROJECT_SOURCE_DIR}/shaders/env/water.slang:waterVS:vertex
    ${PROJECT_SOURCE_DIR}/shaders/env/water.slang:waterPS:fragment
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:treeVS:vertex
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:treePS:fragment
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:impostorVS:vertex
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:impostorPS:fragment
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:grassVS:vertex
    ${PROJECT_SOURCE_DIR}/shaders/env/vegetation.slang:grassPS:fragment)
