# Script runtime (P2b, docs/EVOLUTION.md §4): JavaScriptCore on macOS (system framework) + QuickJS (quickjs-ng,
# official GitHub release source) everywhere; QuickJS is the default engine on Windows. Included from
# src/core/CMakeLists.txt.
include(FetchContent)
set(QJS_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(QJS_BUILD_LIBC OFF CACHE BOOL "" FORCE)
FetchContent_Declare(quickjs
  URL https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz
  URL_HASH SHA256=559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  EXCLUDE_FROM_ALL)
FetchContent_MakeAvailable(quickjs)

set(_pw_script_cpp ${CMAKE_CURRENT_BINARY_DIR}/embedded_scripts.cpp)
set(_pw_script_blobs
  "prelude.js=${CMAKE_CURRENT_SOURCE_DIR}/src/script/prelude.js"
  "neural-controller.json=${PROJECT_SOURCE_DIR}/data/experiments/neural-controller.json"
  "craft-design.json=${PROJECT_SOURCE_DIR}/data/experiments/craft-design.json"
  "coevolve.json=${PROJECT_SOURCE_DIR}/data/experiments/coevolve.json")
file(GLOB _pw_example_experiments CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/examples/experiments/*.json)
foreach(f IN LISTS _pw_example_experiments)
  get_filename_component(n "${f}" NAME)
  list(APPEND _pw_script_blobs "examples/${n}=${f}")
endforeach()
# world files the example experiments reference ("../worlds/<file>"), so an example opened from the app's menu is
# self-contained (the app inlines them)
file(GLOB _pw_example_worlds CONFIGURE_DEPENDS ${PROJECT_SOURCE_DIR}/examples/worlds/*.json)
foreach(f IN LISTS _pw_example_worlds)
  get_filename_component(n "${f}" NAME)
  list(APPEND _pw_script_blobs "worlds/${n}=${f}")
endforeach()
set(_pw_script_files)
foreach(pair IN LISTS _pw_script_blobs)
  string(FIND "${pair}" "=" eq)
  math(EXPR p1 "${eq} + 1")
  string(SUBSTRING "${pair}" ${p1} -1 path)
  list(APPEND _pw_script_files "${path}")
endforeach()
string(REPLACE ";" "|" _pw_script_blobs_arg "${_pw_script_blobs}")
add_custom_command(OUTPUT ${_pw_script_cpp}
  COMMAND ${CMAKE_COMMAND} "-DOUT=${_pw_script_cpp}" "-DNS=pw::script::embedded_experiments" "-DBLOBS=${_pw_script_blobs_arg}"
          -P ${PROJECT_SOURCE_DIR}/cmake/PWEmbedBlobs.cmake
  DEPENDS ${_pw_script_files} ${PROJECT_SOURCE_DIR}/cmake/PWEmbedBlobs.cmake
  COMMENT "Embedding script prelude and experiment presets"
  VERBATIM)

target_sources(pwcore PRIVATE
  src/script/runtime.cpp
  src/train_request.cpp
  src/script/prelude.cpp
  src/script/presets.cpp
  src/script/engine_quickjs.cpp
  src/script/script_selftests.cpp
  ${_pw_script_cpp})
target_link_libraries(pwcore PRIVATE qjs)
if(APPLE)
  target_sources(pwcore PRIVATE src/script/engine_jsc.cpp)
  target_link_libraries(pwcore PUBLIC "-framework JavaScriptCore")
endif()
