# pwflow (P4): GPU lattice-Boltzmann CFD (port of Sources/Flow) on the pwgpu compute layer, Slang kernels.
add_library(pwflow STATIC
  src/part_sdf.cpp
  src/lbm.cpp
  src/flow_selftests.cpp)
target_include_directories(pwflow PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} PRIVATE ${PROJECT_SOURCE_DIR}/shaders/include)
target_link_libraries(pwflow PUBLIC pwcore pwgpu)
pw_add_slang_library(pwflow NAMESPACE pw::flow_shaders HEADER pw/flow_shaders.h
  SHADERS
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang
  DEPENDS ${PROJECT_SOURCE_DIR}/shaders/flow/lbm_common.slang
  ENTRIES
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmVoxelize:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmInit:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmRegrid:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmRescale:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmClear:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmStep:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmRestrict:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmMass:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmSample:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmSlice:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmParticles:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmVoxelize:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmInit:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmRegrid:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmRescale:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmClear:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmStep:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmRestrict:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmMass:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmSample:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmSlice:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmParticles:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmVoxelize:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmInit:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmRegrid:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmRescale:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmStep:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmRestrict:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmVoxelize:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmInit:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmRegrid:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmRescale:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmStep:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmRestrict:compute16)

# pwflow_render: the flow overlay (slice quad + tracers) for the pwrender Renderer; shader shaders/flow_overlay.slang
# lives in the renderer's library (pw_shaders).
add_library(pwflow_render STATIC render/flow_overlay.cpp)
target_include_directories(pwflow_render PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/render)
target_link_libraries(pwflow_render PUBLIC pwflow pwrender)

# pwflow_fv: GPU finite-volume incompressible Navier–Stokes backend (pw/flow/ns.h, docs/CFD_NS.md) and the
# OpenFOAM offline reference (case export / run / force import: pw/flow/openfoam.h; files + subprocess, not linked).
add_library(pwflow_fv STATIC
  src/fv_ns.cpp
  src/fv_selftests.cpp
  src/openfoam.cpp)
target_include_directories(pwflow_fv PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} PRIVATE ${PROJECT_SOURCE_DIR}/shaders/include)
target_link_libraries(pwflow_fv PUBLIC pwflow)
set(PW_FV_ENTRIES "")
foreach(e nsVoxelize nsShift nsMomentum nsIBM nsBC nsDivergence nsProject mgSmooth mgRestrict mgProlong mgCoarse mgResidual
          nsTurbulence nsForces nsSample nsFill nsClear)
  list(APPEND PW_FV_ENTRIES ${PROJECT_SOURCE_DIR}/shaders/flow/fv_ns.slang:${e}:compute)
endforeach()
pw_add_slang_library(pwflow_fv NAMESPACE pw::fv_shaders HEADER pw/fv_shaders.h
  SHADERS ${PROJECT_SOURCE_DIR}/shaders/flow/fv_ns.slang
  ENTRIES ${PW_FV_ENTRIES})
