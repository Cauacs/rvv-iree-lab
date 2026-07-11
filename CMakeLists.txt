cmake_minimum_required(VERSION 3.16)

project(
    rvv_iree_lab
    VERSION 0.1.0
    LANGUAGES C
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(arch-info
    src/main.c
)

if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(arch-info PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Werror
    )
endif()

enable_testing()

add_test(
    NAME arch-info-smoke
    COMMAND arch-info
)

set_tests_properties(
    arch-info-smoke
    PROPERTIES
    PASS_REGULAR_EXPRESSION "architecture="
)
