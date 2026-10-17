# Craft, collision and world sources of pwcore (P1b). Included from src/core/CMakeLists.txt.
set(_pw_crafts_cpp ${CMAKE_CURRENT_BINARY_DIR}/embedded_crafts.cpp)
set(_pw_presets
  "Trainer=${PROJECT_SOURCE_DIR}/data/crafts/trainer.json"
  "Jet trainer=${PROJECT_SOURCE_DIR}/data/crafts/jet-trainer.json"
  "Rover=${PROJECT_SOURCE_DIR}/data/crafts/rover.json"
  "Sounding rocket=${PROJECT_SOURCE_DIR}/data/crafts/sounding-rocket.json")
set(_pw_examples "Ducted rocket=${PROJECT_SOURCE_DIR}/examples/crafts/ducted-rocket.json")
set(_pw_craft_files)
foreach(pair IN LISTS _pw_presets _pw_examples)
  string(FIND "${pair}" "=" eq)
  math(EXPR p1 "${eq} + 1")
  string(SUBSTRING "${pair}" ${p1} -1 path)
  list(APPEND _pw_craft_files "${path}")
endforeach()
string(REPLACE ";" "|" _pw_presets_arg "${_pw_presets}")
string(REPLACE ";" "|" _pw_examples_arg "${_pw_examples}")
add_custom_command(OUTPUT ${_pw_crafts_cpp}
  COMMAND ${CMAKE_COMMAND} "-DOUT=${_pw_crafts_cpp}" "-DPRESETS=${_pw_presets_arg}" "-DEXAMPLES=${_pw_examples_arg}"
          -P ${PROJECT_SOURCE_DIR}/cmake/PWEmbedCrafts.cmake
  DEPENDS ${_pw_craft_files} ${PROJECT_SOURCE_DIR}/cmake/PWEmbedCrafts.cmake
  COMMENT "Embedding craft JSON"
  VERBATIM)

target_sources(pwcore PRIVATE
  src/geo.cpp
  src/craft/document.cpp
  src/craft/mesh.cpp
  src/craft/outputs.cpp
  src/craft/autorig.cpp
  src/craft/meshcut.cpp
  src/craft/cad.cpp
  src/craft/library.cpp
  src/world/document.cpp
  src/world/bake.cpp
  src/collision/convex.cpp
  src/collision/world.cpp
  src/craft_world_selftests.cpp
  ${_pw_crafts_cpp})
if(APPLE)
  target_sources(pwcore PRIVATE src/craft/cad_modelio.mm)
  set_source_files_properties(src/craft/cad_modelio.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(pwcore PUBLIC "-framework Foundation" "-framework ModelIO")
endif()
