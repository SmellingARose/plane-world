add_executable(pwcli main.cpp bench.cpp)
target_link_libraries(pwcli PRIVATE pwcore pwgpu)
