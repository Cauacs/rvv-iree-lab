#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <riscv_vector.h>

enum { ELEMENT_COUNT = 257 };

static void scalar_add(
    const int32_t *lhs,
    const int32_t *rhs,
    int32_t *result,
    size_t count)
{
    for (size_t index = 0; index < count; ++index) {
        result[index] = lhs[index] + rhs[index];
    }
}

static int vector_add(
    const int32_t *lhs,
    const int32_t *rhs,
    int32_t *result,
    size_t count)
{
    size_t remaining = count;

    while (remaining > 0) {
        const size_t vl = __riscv_vsetvl_e32m1(remaining);

        if (vl == 0) {
            fprintf(
                stderr,
                "rvv.vector_add: FAIL active-vl=0 remaining=%zu\n",
                remaining);
            return -1;
        }

        const vint32m1_t lhs_vector = __riscv_vle32_v_i32m1(lhs, vl);
        const vint32m1_t rhs_vector = __riscv_vle32_v_i32m1(rhs, vl);
        const vint32m1_t sum_vector =
            __riscv_vadd_vv_i32m1(lhs_vector, rhs_vector, vl);

        __riscv_vse32_v_i32m1(result, sum_vector, vl);

        lhs += vl;
        rhs += vl;
        result += vl;
        remaining -= vl;
    }

    return 0;
}

int main(void)
{
    const size_t vlmax_e32m1 = __riscv_vsetvlmax_e32m1();
    int32_t lhs[ELEMENT_COUNT];
    int32_t rhs[ELEMENT_COUNT];
    int32_t scalar_result[ELEMENT_COUNT];
    int32_t vector_result[ELEMENT_COUNT];

    if (vlmax_e32m1 == 0) {
        fputs("rvv.vector_add: FAIL vlmax_e32m1=0\n", stderr);
        return 2;
    }

    if (vlmax_e32m1 >= ELEMENT_COUNT) {
        fprintf(
            stderr,
            "rvv.vector_add: FAIL elements=%d does-not-exceed "
            "vlmax_e32m1=%zu\n",
            ELEMENT_COUNT,
            vlmax_e32m1);
        return 2;
    }

    for (size_t index = 0; index < ELEMENT_COUNT; ++index) {
        lhs[index] = (int32_t)index - 128;
        rhs[index] = (int32_t)(index * 3) - 256;
    }

    scalar_add(lhs, rhs, scalar_result, ELEMENT_COUNT);

    if (vector_add(lhs, rhs, vector_result, ELEMENT_COUNT) != 0) {
        return 2;
    }

    for (size_t index = 0; index < ELEMENT_COUNT; ++index) {
        if (vector_result[index] != scalar_result[index]) {
            fprintf(
                stderr,
                "rvv.vector_add: FAIL index=%zu expected=%" PRId32
                " actual=%" PRId32 "\n",
                index,
                scalar_result[index],
                vector_result[index]);
            return 1;
        }
    }

    printf(
        "rvv.vector_add: PASS elements=%d vlmax_e32m1=%zu\n",
        ELEMENT_COUNT,
        vlmax_e32m1);

    return 0;
}
