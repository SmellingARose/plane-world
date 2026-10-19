add_executable(pwcli main.cpp bench.cpp alloc_count.cpp train_cli.cpp aero_compare.cpp)
target_link_libraries(pwcli PRIVATE pwcore pwgpu pwrender pwenv pwenv_render pwflow pwflow_render pwflow_fv)
