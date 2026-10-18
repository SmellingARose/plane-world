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
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmRescale:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmClear:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmStep:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmMass:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmSample:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmSlice:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19.slang:lbmParticles:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmVoxelize:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmInit:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmRescale:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmClear:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmStep:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmMass:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmSample:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmSlice:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27.slang:lbmParticles:compute
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmVoxelize:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmInit:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmRescale:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm19h.slang:lbmStep:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmVoxelize:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmInit:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmRescale:compute16
    ${PROJECT_SOURCE_DIR}/shaders/flow/lbm27h.slang:lbmStep:compute16)

# pwflow_render: the flow overlay (slice quad + tracers) for the pwrender Renderer; shader shaders/flow_overlay.slang
# lives in the renderer's library (pw_shaders).
add_library(pwflow_render STATIC render/flow_overlay.cpp)
target_include_directories(pwflow_render PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/render)
target_link_libraries(pwflow_render PUBLIC pwflow pwrender)
