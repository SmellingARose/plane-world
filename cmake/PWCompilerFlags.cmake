# Determinism rules (docs/PORT_PLAN.md "Making sure both platforms compute the same thing"):
#   no hidden FMA contraction, no fast-math, strict IEEE semantics on every compiler.
add_library(pw_flags INTERFACE)
if(MSVC)
  # /fp:precise does not contract a*b+c into FMA unless /fp:contract is given (VS 2022 17.x default: off).
  target_compile_options(pw_flags INTERFACE /fp:precise /W4 /permissive- /Zc:__cplusplus /utf-8 /EHsc /wd4324)
  target_compile_definitions(pw_flags INTERFACE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(pw_flags INTERFACE -ffp-contract=off -fno-fast-math -Wall -Wextra -Wno-unused-parameter)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(pw_flags INTERFACE -fno-finite-math-only)
  endif()
endif()
