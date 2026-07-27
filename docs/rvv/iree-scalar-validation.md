# Scalar IREE Runtime Validation

## Completion status

The scalar IREE validation is complete for repository commit `34472877d451b67b36dbb8fe75516c1ced0eeb1c`. That commit is contained by `origin/main`. The generated artifacts below were regenerated at that commit and validated twice on the physical Orange Pi RV2 using the dynamic runtime.

## Source and dependency identity

- Repository commit: `34472877d451b67b36dbb8fe75516c1ced0eeb1c`
- IREE source revision: `dc9601f88654749456c7cee4ae87e13de2654e1e`
- Reported compiler version: `IREE compiler version (unknown)`
- LLVM version: `24.0.0git`
- IREE host archive: `iree-dist-3.12.0rc20260721-linux-x86_64.tar.xz`
- IREE host archive SHA-256: `c47955d09664e2d0750bd0e2cbf801953d42b164474705fee646ec749ac15202`
- RISC-V toolchain archive: `toolchain_iree_manylinux_2_28_20231012.tar.gz`
- RISC-V toolchain archive SHA-256: `3af56a58551ed5ae7441214822461a5368fee9403d7c883762fa902489bfbff0`
- Configuration: `scripts/iree/iree.env`
- Configuration SHA-256: `4bcc673f857f54e039feafe08ce0040f8ed3c5ced7c3a5b6deaf77d4d3f116ff`
- Tensor source: `src/iree/tensor_add.mlir`
- Tensor source SHA-256: `541e076f5123a22f1479c70338181ffd874e8dd1218896a716736fe1dc61b9f8`
- Toolchain report: `build/iree/toolchain-versions.txt`
- Toolchain report SHA-256: `5437f6bd146d6eb4fbbd1485d0937799c5ebf432c489446fd4f1965fb776b611`

The scalar compile target is `riscv64`, ABI `lp64d`, CPU features `+m,+a,+f,+d,+c`, and optimization level `O2`.

## Compile artifacts

`./scripts/iree/compile_tensor_add.sh` compiled and executed the host oracle successfully before producing the scalar VMFB. The host run reported exactly one `[SUCCESS] all function outputs matched their expected values.` for:

- function: `add`
- left input: `4xf32=1 2 3 4`
- right input: `4xf32=10 20 30 40`
- expected output: `4xf32=11 22 33 44`

Accepted compile evidence:

- Compile manifest: `build/iree/compile-manifest.txt`
- Compile manifest SHA-256: `d8ac568f4391d5a90fd247f80b3dcf8504a80191b3b3eea17382f19b32b9bb05`
- Scalar VMFB: `build/iree/scalar/tensor_add.vmfb`
- Scalar VMFB SHA-256: `e4da0ca042260bf3b5d68b837a46a21ec2453a08d393bcc7f865519cea334ed4`
- Scalar sidecar: `build/iree/scalar/tensor_add.vmfb.sha256`
- Scalar sidecar SHA-256: `99faa78cca2499351608390562fad3cbf2f2c08b54ec89bf6a3f6cd76020b45f`

The manifest binds these artifacts to repository commit `34472877d451b67b36dbb8fe75516c1ced0eeb1c`, the source/configuration hashes above, and IREE revision `dc9601f88654749456c7cee4ae87e13de2654e1e`.

## Runtime artifacts

The accepted runtime linkage is `dynamic`. No static fallback was required: the board provided every dynamic dependency and `ldd` reported no missing library.

`RUNTIME_LINKAGE=dynamic ./scripts/iree/build_riscv_runtime.sh` configured the runtime with the embedded ELF loader and disabled RISC-V vector ukernels:

- `-DIREE_UK_BUILD_RISCV_64_V=OFF`
- `-DIREE_UK_BUILD_RISCV_64_ZVFH=OFF`
- `-DIREE_UK_BUILD_RISCV_64_ZVFHMIN=OFF`

Accepted runtime evidence:

- Runtime manifest: `build/iree/runtime-manifest.txt`
- Runtime manifest SHA-256: `fbba6d8778a0a6e37e8c860f30a33431d5f627f20909a7eda5d2d8e28812cec7`
- Runner: `build/iree/runtime-riscv64/tools/iree-run-module`
- Runner SHA-256: `f14a07e36bc5590469cac0fe2a4317d55906fbd5fe0abdc7eef6b6ea40f35c22`
- Runner sidecar: `build/iree/runtime-riscv64/iree-run-module.sha256`
- Runner sidecar SHA-256: `80fa5305cf9db70a4afe700272e9b572a19546945a7d1a5cfa5f571e9041cf59`

The runner is an ELF64 RISC-V PIE with the double-float ABI and dynamic interpreter `/lib/ld-linux-riscv64-lp64d.so.1`. Its RISC-V architecture attributes contain no vector extension.

## Physical-board validation

Board host: `orangepi-rv2`. Both runs used `scripts/iree/run_scalar_on_board.sh`, the accepted dynamic runner, the same scalar VMFB, `--device=local-task`, and the exact host-oracle tensors. Each run verified transferred SHA-256 sidecars, `uname -m=riscv64`, the runner ELF identity, and all dynamic dependencies before execution. Each produced exit status zero and exactly one IREE numerical-success line.

1. `build/iree/phase2-board-runs/dynamic-run-1.txt`
   - SHA-256: `a945105f0ea26e78e87e72d136c1dc81319fa0c45464dab222e70600058e7364`
   - Result: `PASS`
2. `build/iree/phase2-board-runs/dynamic-run-2.txt`
   - SHA-256: `5dfec5fb791250ba1cb11d81629490599005b2ec2fdffb0e9122a0f4cf0dc062`
   - Result: `PASS`

Observed board identity in both logs:

- Architecture: `riscv64`
- OS: Armbian community 26.8.0-trunk.170 / Debian 13
- glibc: `2.41`
- Runner linkage: dynamic; no dependency reported `not found`

## Acceptance

Scalar IREE acceptance is satisfied for commit `34472877d451b67b36dbb8fe75516c1ced0eeb1c`: dependency identities are pinned, host correctness passed, compile and runtime artifacts are commit/hash bound, the runtime is scalar, dynamic dependencies are available, and two independent physical-board executions produced the expected tensor output.
