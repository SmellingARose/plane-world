add_executable(pwcli main.cpp bench.cpp alloc_count.cpp)
target_link_libraries(pwcli PRIVATE pwcore pwgpu)
