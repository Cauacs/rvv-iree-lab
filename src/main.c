#include <stdio.h>

int main(void)
{
#if defined(__riscv)
    printf("architecture=riscv xlen=%d\n", __riscv_xlen);
#elif defined(__x86_64__)
    puts("architecture=x86_64");
#elif defined(__aarch64__)
    puts("architecture=aarch64");
#else
    puts("architecture=unknown");
#endif

#if defined(__riscv_vector)
    puts("rvv=enabled");
#else
    puts("rvv=not-enabled");
#endif

    return 0;
}
