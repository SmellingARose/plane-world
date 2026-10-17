# Slang shader toolchain. Finds slangc (PW_SLANGC, SLANG_DIR, PATH, ~/.local/slang-*), and on Windows dxc.exe
# from the Windows SDK. pw_add_slang_shaders(<target> FILES a.slang ...) compiles each file:
#   Apple:   slangc -target metal  -> <name>.metal (MSL source, compiled at runtime by MTLDevice newLibraryWithSource)
#   Windows: slangc -target hlsl (per entry) -> dxc (Windows SDK) -> <name>.vs.dxil / <name>.ps.dxil
# and embeds the outputs as byte arrays in a generated C++ source (pw::shaders::find("<name>.<stage>")).
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

function(pw_add_slang_shaders target)
  cmake_parse_arguments(A "" "" "FILES" ${ARGN})
  set(outdir ${CMAKE_CURRENT_BINARY_DIR}/shaders)
  file(MAKE_DIRECTORY ${outdir})
  set(blobs "")
  foreach(src IN LISTS A_FILES)
    get_filename_component(name ${src} NAME_WE)
    get_filename_component(abs ${src} ABSOLUTE)
    if(APPLE)
      set(out ${outdir}/${name}.metal)
      add_custom_command(OUTPUT ${out}
        COMMAND ${PW_SLANGC} ${abs} -target metal -o ${out}
        DEPENDS ${abs} COMMENT "Slang -> MSL ${name}" VERBATIM)
      list(APPEND blobs "${name}.metal=${out}")
      set(deps ${deps} ${out})
    elseif(WIN32)
      foreach(stage vs ps)
        if(stage STREQUAL "vs")
          set(entry vsMain)
          set(sstage vertex)
          set(profile vs_6_0)
        else()
          set(entry psMain)
          set(sstage fragment)
          set(profile ps_6_0)
        endif()
        set(hlsl ${outdir}/${name}.${stage}.hlsl)
        set(out ${outdir}/${name}.${stage}.dxil)
        add_custom_command(OUTPUT ${out}
          COMMAND ${PW_SLANGC} ${abs} -target hlsl -entry ${entry} -stage ${sstage} -o ${hlsl}
          COMMAND ${PW_DXC} -nologo -T ${profile} -E ${entry} -Fo ${out} ${hlsl}
          DEPENDS ${abs} COMMENT "Slang -> HLSL -> DXIL ${name}.${stage}" VERBATIM)
        list(APPEND blobs "${name}.${stage}=${out}")
        set(deps ${deps} ${out})
      endforeach()
    endif()
  endforeach()
  set(gen ${CMAKE_CURRENT_BINARY_DIR}/pw_shader_blobs.cpp)
  add_custom_command(OUTPUT ${gen}
    COMMAND ${CMAKE_COMMAND} -DOUT=${gen} "-DBLOBS=${blobs}" -P ${PROJECT_SOURCE_DIR}/cmake/PWEmbed.cmake
    DEPENDS ${deps} ${PROJECT_SOURCE_DIR}/cmake/PWEmbed.cmake COMMENT "Embedding shaders" VERBATIM)
  target_sources(${target} PRIVATE ${gen})
endfunction()
