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

option(ENABLE_RVV_EXPERIMENTS "Build RVV hardware experiments" OFF)

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

if(ENABLE_RVV_EXPERIMENTS)
    set(RVV_MARCH rv64gcv)
    set(RVV_MABI lp64d)

    if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "riscv64")
        message(FATAL_ERROR
            "ENABLE_RVV_EXPERIMENTS requires a native riscv64 build"
        )
    endif()

    if(NOT CMAKE_C_COMPILER_ID STREQUAL "GNU")
        message(FATAL_ERROR
            "ENABLE_RVV_EXPERIMENTS requires the GNU C compiler"
        )
    endif()

    include(CheckCSourceCompiles)

    set(
        RVV_SAVED_CMAKE_REQUIRED_FLAGS
        "${CMAKE_REQUIRED_FLAGS}"
    )
    set(
        CMAKE_REQUIRED_FLAGS
        "${CMAKE_REQUIRED_FLAGS} -march=${RVV_MARCH} -mabi=${RVV_MABI}"
    )

    check_c_source_compiles(
        [=[
            #include <stddef.h>
            #include <riscv_vector.h>

            int main(void)
            {
                const size_t vl = __riscv_vsetvl_e32m1(1);
                return vl == 0;
            }
        ]=]
        RVV_INTRINSICS_SUPPORTED
    )

    set(
        CMAKE_REQUIRED_FLAGS
        "${RVV_SAVED_CMAKE_REQUIRED_FLAGS}"
    )
    unset(RVV_SAVED_CMAKE_REQUIRED_FLAGS)

    if(NOT RVV_INTRINSICS_SUPPORTED)
        message(FATAL_ERROR
            "ENABLE_RVV_EXPERIMENTS requires GCC RVV intrinsics for "
            "-march=${RVV_MARCH} -mabi=${RVV_MABI}"
        )
    endif()

    add_executable(rvv_vector_add
        src/rvv/vector_add.c
    )

    target_compile_options(rvv_vector_add PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -Werror
        -fno-tree-vectorize
        "-march=${RVV_MARCH}"
        "-mabi=${RVV_MABI}"
    )

    target_link_options(rvv_vector_add PRIVATE
        "-march=${RVV_MARCH}"
        "-mabi=${RVV_MABI}"
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

if(ENABLE_RVV_EXPERIMENTS)
    add_test(
        NAME rvv.vector_add
        COMMAND rvv_vector_add
    )

    set_tests_properties(
        rvv.vector_add
        PROPERTIES
        PASS_REGULAR_EXPRESSION
            "rvv.vector_add: PASS elements=257 vlmax_e32m1=[1-9][0-9]*"
    )
endif()
