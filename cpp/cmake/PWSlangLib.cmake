# Named Slang shader libraries (P3b: terrain / water / vegetation). Unlike pw_add_slang_shaders (vs/ps only),
# any entry point and stage is supported, and blobs land in their own namespace so libraries do not collide:
#   pw_add_slang_library(<target> NAMESPACE <ns> HEADER <pw/x.h>
#                        SHADERS <file.slang>... ENTRIES <file>:<entry>:<stage>...)
#   Apple:   slangc -target metal per file          -> key "<file>.metal" (MSL source, compiled at runtime)
#   Windows: slangc -target hlsl -entry per entry   -> dxc (cs_6_0 / vs_6_0 / ps_6_0) -> key "<file>.<entry>" (DXIL)
# Lookup: <ns>::find("<key>") returns a pw::shaders::Blob (same struct as pw/shaders.h).
function(pw_add_slang_library target)
  cmake_parse_arguments(A "" "NAMESPACE;HEADER" "SHADERS;ENTRIES;INCLUDES" ${ARGN})
  set(outdir ${CMAKE_CURRENT_BINARY_DIR}/${target})
  file(MAKE_DIRECTORY ${outdir})
  set(blobs "")
  set(deps "")
  set(incflags "")
  foreach(inc IN LISTS A_INCLUDES)
    list(APPEND incflags -I ${inc})
  endforeach()
  foreach(src IN LISTS A_SHADERS)
    get_filename_component(name ${src} NAME_WE)
    get_filename_component(abs ${src} ABSOLUTE)
    if(APPLE)
      set(out ${outdir}/${name}.metal)
      add_custom_command(OUTPUT ${out}
        COMMAND ${PW_SLANGC} ${abs} ${incflags} -target metal -o ${out}
        DEPENDS ${abs} COMMENT "Slang -> MSL ${name}" VERBATIM)
      list(APPEND blobs "${name}.metal=${out}")
      list(APPEND deps ${out})
    endif()
  endforeach()
  if(WIN32)
    foreach(e IN LISTS A_ENTRIES)
      string(REPLACE ":" ";" parts "${e}")
      list(GET parts 0 file)
      list(GET parts 1 entry)
      list(GET parts 2 stage)
      get_filename_component(name ${file} NAME_WE)
      get_filename_component(abs ${file} ABSOLUTE)
      if(stage STREQUAL "compute")
        set(profile cs_6_0)
      elseif(stage STREQUAL "vertex")
        set(profile vs_6_0)
      elseif(stage STREQUAL "fragment")
        set(profile ps_6_0)
      else()
        message(FATAL_ERROR "pw_add_slang_library: unknown stage ${stage}")
      endif()
      set(hlsl ${outdir}/${name}.${entry}.hlsl)
      set(out ${outdir}/${name}.${entry}.dxil)
      add_custom_command(OUTPUT ${out}
        COMMAND ${PW_SLANGC} ${abs} ${incflags} -target hlsl -entry ${entry} -stage ${stage} -o ${hlsl}
        COMMAND ${PW_DXC} -nologo -T ${profile} -E ${entry} -Fo ${out} ${hlsl}
        DEPENDS ${abs} COMMENT "Slang -> HLSL -> DXIL ${name}.${entry}" VERBATIM)
      list(APPEND blobs "${name}.${entry}=${out}")
      list(APPEND deps ${out})
    endforeach()
  endif()
  set(gen ${CMAKE_CURRENT_BINARY_DIR}/${target}_blobs.cpp)
  add_custom_command(OUTPUT ${gen}
    COMMAND ${CMAKE_COMMAND} -DOUT=${gen} "-DBLOBS=${blobs}" -DNS=${A_NAMESPACE} -DHEADER=${A_HEADER}
            -P ${PROJECT_SOURCE_DIR}/cmake/PWEmbedNs.cmake
    DEPENDS ${deps} ${PROJECT_SOURCE_DIR}/cmake/PWEmbedNs.cmake COMMENT "Embedding ${target} shaders" VERBATIM)
  target_sources(${target} PRIVATE ${gen})
endfunction()
