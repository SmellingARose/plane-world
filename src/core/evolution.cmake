# Evolution sources of pwcore (P2a). Included from src/core/CMakeLists.txt.
target_sources(pwcore PRIVATE
  src/evo/types.cpp
  src/evo/algos_basic.cpp
  src/evo/algos_cma.cpp
  src/evo/algos_qd.cpp
  src/evo/experiment.cpp
  src/evo/presets_js.cpp
  src/evo/policy.cpp
  src/evo/script.cpp
  src/evo/evaluator.cpp
  src/evo/run.cpp
  src/evo/train.cpp
  src/evo/evolution_selftests.cpp)
