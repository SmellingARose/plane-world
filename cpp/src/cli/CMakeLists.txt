add_executable(pwcli main.cpp bench.cpp alloc_count.cpp train_cli.cpp)
target_link_libraries(pwcli PRIVATE pwcore pwgpu)
