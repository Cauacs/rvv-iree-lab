# Orange Pi RV2 RVV hardware validation

Validation was performed on 2026-07-17 against source commit
`26d226de8e7fa0dde332738d9da5587dbb11141b`. The current
`scripts/remote-board-validate.sh` implementation was streamed over SSH, used a
temporary checkout and build directory, and removed both after completion. The
validator ran the capability collector, compiler matrix, RVV-enabled CMake
build, CTest, direct executable check, ELF check, and disassembly assertions.

## Board and operating system

- Board: Orange Pi RV2
- Processor: SpacemiT X60
- Harts: 8
- Architecture: `riscv64`
- Operating system: Armbian community `26.8.0-trunk.170`, Debian 13.5
  (`trixie`)
- Kernel:

  ```text
  Linux orangepirv2 6.18.35-current-spacemit #3 SMP PREEMPT_DYNAMIC Tue Jun  9 13:38:30 UTC 2026 riscv64 GNU/Linux
  ```

- CPU identifiers, identical for all eight harts:

  ```text
  mvendorid : 0x710
  marchid   : 0x8000000058000001
  mimpid    : 0x1000000049772200
  uarch     : spacemit,x60
  ```

## ISA and userspace capability evidence

`/proc/cpuinfo` reported the same ISA and hart ISA for all eight harts:

```text
rv64imafdcv_zicbom_zicboz_zicntr_zicond_zicsr_zifencei_zihintpause_zihpm_zaamo_zalrsc_zfh_zfhmin_zca_zcd_zba_zbb_zbc_zbs_zkt_zve32f_zve32x_zve64d_zve64f_zve64x_zvfh_zvfhmin_zvkt_sscofpmf_sstc_svinval_svnapot_svpbmt
```

The device tree reported the same values for `cpu@0` through `cpu@7`:

```text
compatible            = spacemit,x60; riscv
riscv,isa              = rv64imafdcv
riscv,isa-base         = rv64i
riscv,isa-extensions   = i m a f d c v zicbom zicboz zicntr zicond zicsr zifencei zihintpause zihpm zfh zfhmin zba zbb zbc zbs zkt zvfh zvfhmin zvkt sscofpmf sstc svinval svnapot svpbmt
riscv,vlenb            = unavailable
```

Additional userspace evidence:

```text
/proc/sys/abi/riscv_v_default_allow = 1
AT_HWCAP                              = 20112d
```

The kernel and device tree agree that the standard `v` extension is exposed.
The kernel ISA string additionally reports the embedded-vector subsets
`zve32*` and `zve64*`; the device-tree extension list does not include those
names. The device tree exposes neither a vector length nor an explicit RVV
revision.

## Compiler and flag probe

Compiler:

```text
cc (Debian 14.2.0-19) 14.2.0
Target: riscv64-linux-gnu
Default -march: rv64imafdc_zicsr_zifencei
Default -mabi:  lp64d
```

The default compiler target does not enable RVV. Standard GCC
`<riscv_vector.h>` intrinsics were available when an RVV `-march` was selected.

| Configuration | Compile | Assemble | Link | Execute |
| --- | --- | --- | --- | --- |
| `-march=rv64gcv -mabi=lp64d` | PASS | PASS | PASS | PASS, exit 0 |
| `-march=rv64gcv_zvl128b -mabi=lp64d` | PASS | PASS | PASS | PASS, exit 0 |
| `-march=rv64imafdcv -mabi=lp64d` | PASS | PASS | PASS | PASS, exit 0 |
| `-march=rv64gcv -mabi=lp64` | FAIL | SKIP | SKIP | SKIP |

The `lp64` row failed during compilation because the installed Debian
userspace does not provide `gnu/stubs-lp64.h`. The first complete success was
selected:

```text
-march=rv64gcv -mabi=lp64d
```

This is the shortest standard spelling accepted by the compiler and executed
by the board. The target-owned CMake flags make the ISA and ABI reproducible
without changing the portable `arch-info` target.

Selected-target macros, captured with `<riscv_vector.h>` included:

```text
#define __riscv_v_intrinsic 12000
#define __riscv_v_min_vlen 128
#define __riscv_v 1000000
#define __riscv_vector 1
```

These values describe GCC's selected standard V target, intrinsic API, and
minimum target VLEN. They do not independently identify the X60 hardware's RVV
revision.

## Build and runtime result

The RVV-enabled Release configuration passed its configure-time intrinsic
check, built both executables, and passed both tests:

```text
Test #1: arch-info-smoke    Passed
Test #2: rvv.vector_add     Passed
100% tests passed, 0 tests failed out of 2
```

The portable target remained compiled without RVV flags and reported:

```text
architecture=riscv xlen=64
rvv=not-enabled
```

That output describes the target-scoped compiler configuration, not the
hardware capability. The separate RVV target executed its vector-length-
agnostic loop, compared all 257 outputs against its scalar reference, and
returned exit code 0:

```text
rvv.vector_add: PASS elements=257 vlmax_e32m1=8
```

For SEW=32 and LMUL=1, the observed maximum active vector length was 8
elements, so the runtime-observed VLEN was:

```text
8 elements × 32 bits = 256 bits
```

The 257-element fixture therefore required multiple vector iterations and did
not rely on a fixed VLEN.

`file` identified the executable as:

```text
ELF 64-bit LSB pie executable, UCB RISC-V, RVC, double-float ABI, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-riscv64-lp64d.so.1, for GNU/Linux 4.15.0, not stripped
```

## Disassembly evidence

GNU objdump 2.44 emitted and the validator required all four instruction
classes:

```text
704: 0d05f7d7  vsetvli a5,a1,e32,m1,ta,ma
70e: 02036087  vle32.v v1,(t1)
71c: 021100d7  vadd.vv v1,v1,v2
720: 020860a7  vse32.v v1,(a6)
```

Compilation flags alone were not treated as proof: successful execution and
these decoded RVV instructions provide the hardware validation.

## Conclusion and limitation

The Orange Pi RV2 successfully executes standard RVV load, integer-add, store,
and vector-length-setting instructions with GCC 14.2 using
`-march=rv64gcv -mabi=lp64d`. Runtime behavior establishes a 256-bit VLEN for
SEW=32, LMUL=1 on this board and kernel.

No inspected kernel or device-tree source names the X60 hardware's RVV
revision. GCC's `__riscv_v=1000000` records the compiler target as V 1.0, not an
independent hardware-version declaration; this document therefore does not
claim a specific X60 RVV revision. After the validator changes are committed
and pushed, `./scripts/board-test.sh` should be run once from that clean commit
to reproduce the evidence through the exact-commit developer workflow.
