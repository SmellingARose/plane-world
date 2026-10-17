# Slang shader toolchain. Finds slangc (PW_SLANGC, SLANG_DIR, PATH, ~/.local/slang-*), and on Windows dxc.exe
# from the Windows SDK. pw_add_slang_shaders(<target> FILES a.slang ... DEPENDS common.slang ...) compiles each file:
#   Apple:   slangc -target metal -> <name>.metal (MSL source with every entry point, compiled at runtime by
#            MTLDevice newLibraryWithSource) + <name>.metalbind (storage-texture register -> Metal index, from the
#            Slang reflection JSON; see PWSlangReflect.cmake)
#   Windows: per entry point: slangc -target hlsl -> dxc (Windows SDK) -> <name>.<entry>.dxil
# Entry points are discovered from `[shader("vertex"|"fragment"|"compute")] <type> <name>(` declarations (attribute
# and name on one line; macro-generated kernels are listed with `// pw-entry: <name> <stage>` comments).
# Outputs are embedded as byte arrays (pw::shaders::find("<name>.metal" | "<name>.metalbind" | "<name>.<entry>")).
file(GLOB _pw_local_slang LIST_DIRECTORIES true "$ENV{HOME}/.local/slang-*/bin")
find_program(PW_SLANGC NAMES slangc
  HINTS ENV SLANG_DIR "$ENV{SLANG_DIR}/bin" ${_pw_local_slang}
  REQUIRED)
message(STATUS "slangc: ${PW_SLANGC}")
if(WIN32)
  file(GLOB _pw_sdk_bins LIST_DIRECTORIES true "$ENV{ProgramFiles\(x86\)}/Windows Kits/10/bin/10.*/x64")
  list(SORT _pw_sdk_bins COMPARE NATURAL ORDER DESCENDING)
  find_program(PW_DXC NAMES dxc HINTS ${_pw_sdk_bins} REQUIRED)
  message(STATUS "dxc: ${PW_DXC}")
endif()
set(PW_SLANG_FLAGS -warnings-disable 39029,39001)

# Lists "entry:stage" pairs of a Slang file into <outvar>.
function(pw_slang_entries file outvar)
  file(STRINGS ${file} lines REGEX "\\[shader\\(\"(vertex|fragment|compute)\"\\)\\]|pw-entry:")
  set(result "")
  foreach(l IN LISTS lines)
    if(l MATCHES "^[ \t]*#define" OR l MATCHES "\\\\[ \t]*$")
      continue()   # macro bodies: list those kernels with pw-entry comments
    endif()
    if(l MATCHES "pw-entry:[ \t]*([A-Za-z0-9_]+)[ \t]+(vertex|fragment|compute)")
      list(APPEND result "${CMAKE_MATCH_1}:${CMAKE_MATCH_2}")
    elseif(l MATCHES "\\[shader\\(\"(vertex|fragment|compute)\"\\)\\][ \t]*(\\[[^]]*\\][ \t]*)*[A-Za-z0-9_<>]+[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*\\(")
      list(APPEND result "${CMAKE_MATCH_3}:${CMAKE_MATCH_1}")
    endif()
  endforeach()
  set(${outvar} ${result} PARENT_SCOPE)
endfunction()

function(pw_add_slang_shaders target)
  cmake_parse_arguments(A "" "" "FILES;DEPENDS" ${ARGN})
  set(outdir ${CMAKE_CURRENT_BINARY_DIR}/shaders)
  file(MAKE_DIRECTORY ${outdir})
  set(blobs "")
  set(deps "")
  set(common "")
  foreach(d IN LISTS A_DEPENDS)
    get_filename_component(dabs ${d} ABSOLUTE)
    list(APPEND common ${dabs})
  endforeach()
  foreach(src IN LISTS A_FILES)
    get_filename_component(name ${src} NAME_WE)
    get_filename_component(abs ${src} ABSOLUTE)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${abs})
    if(APPLE)
      set(out ${outdir}/${name}.metal)
      set(refl ${outdir}/${name}.reflect.json)
      set(bind ${outdir}/${name}.metalbind)
      add_custom_command(OUTPUT ${out} ${bind}
        COMMAND ${PW_SLANGC} ${abs} -target metal ${PW_SLANG_FLAGS} -o ${out} -reflection-json ${refl}
        COMMAND ${CMAKE_COMMAND} -DIN=${refl} -DOUT=${bind} -P ${PROJECT_SOURCE_DIR}/cmake/PWSlangReflect.cmake
        DEPENDS ${abs} ${common} ${PROJECT_SOURCE_DIR}/cmake/PWSlangReflect.cmake COMMENT "Slang -> MSL ${name}" VERBATIM)
      list(APPEND blobs "${name}.metal=${out}" "${name}.metalbind=${bind}")
      list(APPEND deps ${out} ${bind})
    elseif(WIN32)
      pw_slang_entries(${abs} entries)
      if(NOT entries)
        message(FATAL_ERROR "${src}: no [shader(...)] entry points found")
      endif()
      foreach(e IN LISTS entries)
        string(REPLACE ":" ";" parts ${e})
        list(GET parts 0 entry)
        list(GET parts 1 sstage)
        if(sstage STREQUAL "vertex")
          set(profile vs_6_0)
        elseif(sstage STREQUAL "fragment")
          set(profile ps_6_0)
        else()
          set(profile cs_6_0)
        endif()
        set(hlsl ${outdir}/${name}.${entry}.hlsl)
        set(out ${outdir}/${name}.${entry}.dxil)
        add_custom_command(OUTPUT ${out}
          COMMAND ${PW_SLANGC} ${abs} -target hlsl ${PW_SLANG_FLAGS} -entry ${entry} -stage ${sstage} -o ${hlsl}
          COMMAND ${PW_DXC} -nologo -T ${profile} -E ${entry} -Fo ${out} ${hlsl}
          DEPENDS ${abs} ${common} COMMENT "Slang -> HLSL -> DXIL ${name}.${entry}" VERBATIM)
        list(APPEND blobs "${name}.${entry}=${out}")
        list(APPEND deps ${out})
      endforeach()
    endif()
  endforeach()
  set(gen ${CMAKE_CURRENT_BINARY_DIR}/pw_shader_blobs.cpp)
  add_custom_command(OUTPUT ${gen}
    COMMAND ${CMAKE_COMMAND} -DOUT=${gen} "-DBLOBS=${blobs}" -P ${PROJECT_SOURCE_DIR}/cmake/PWEmbed.cmake
    DEPENDS ${deps} ${PROJECT_SOURCE_DIR}/cmake/PWEmbed.cmake COMMENT "Embedding shaders" VERBATIM)
  target_sources(${target} PRIVATE ${gen})
endfunction()
