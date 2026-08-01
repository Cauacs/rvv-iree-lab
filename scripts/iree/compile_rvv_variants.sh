#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf 'Usage: compile_variants.sh [--review] [--diagnostic=length-4096|o3]\n' >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

REVIEW=false
DIAGNOSTIC=''
for argument in "$@"; do
  case "$argument" in
    --review) [[ "$REVIEW" == false ]] || { usage; exit 2; }; REVIEW=true ;;
    --diagnostic=length-4096) [[ -z "$DIAGNOSTIC" ]] || { usage; exit 2; }; DIAGNOSTIC=length-4096 ;;
    --diagnostic=o3) [[ -z "$DIAGNOSTIC" ]] || { usage; exit 2; }; DIAGNOSTIC=o3 ;;
    *) usage; exit 2 ;;
  esac
done

for command_name in git mkdir mv rm sha256sum sort tee; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'run from inside the repository'
cd "$REPO_ROOT"

PHASE2_CONFIG=scripts/iree/iree.env
PHASE2_RECORD=docs/rvv/iree-scalar-validation.md
CONFIG=scripts/iree/rvv.env
SOURCE=src/iree/tensor_add_rvv.mlir
PHASE2_SOURCE=src/iree/tensor_add.mlir
DEPS=build/iree/deps
HOST_DIR="$DEPS/iree-host"
TOOLCHAIN_DIR="$DEPS/riscv-toolchain"
IREE_SOURCE_DIR="$DEPS/iree-src"
IREE_COMPILE="$HOST_DIR/bin/iree-compile"
IREE_RUN_MODULE="$HOST_DIR/bin/iree-run-module"
HOST_MARKER="$HOST_DIR/.iree-dependency"
TOOLCHAIN_MARKER="$TOOLCHAIN_DIR/.iree-dependency"

[[ -f "$PHASE2_CONFIG" ]] || die "missing Phase 2 configuration: $PHASE2_CONFIG"
[[ -f "$PHASE2_RECORD" ]] || die "missing scalar validation record: $PHASE2_RECORD"
[[ -f "$CONFIG" ]] || die "missing Phase 3 configuration: $CONFIG"
[[ -f "$SOURCE" ]] || die "missing Phase 3 source: $SOURCE"
[[ -f "$PHASE2_SOURCE" ]] || die "missing immutable Phase 2 source: $PHASE2_SOURCE"
# shellcheck source=/dev/null
. "$PHASE2_CONFIG"
PHASE2_IREE_REVISION="$IREE_REVISION"
PHASE2_IREE_HOST_ARCHIVE="$IREE_HOST_ARCHIVE"
PHASE2_IREE_HOST_SHA256="$IREE_HOST_SHA256"
PHASE2_RISCV_TOOLCHAIN_ARCHIVE="$RISCV_TOOLCHAIN_ARCHIVE"
PHASE2_RISCV_TOOLCHAIN_SHA256="$RISCV_TOOLCHAIN_SHA256"
# shellcheck source=/dev/null
. "$CONFIG"

required_config_keys=(
  SCHEMA_VERSION TARGET_TRIPLE TARGET_ABI SCALAR_CPU_FEATURES RVV_CPU_FEATURES
  OPT_LEVEL EXECUTABLE_FORMAT TENSOR_LENGTH IREE_SOURCE_REVISION
  IREE_COMPILER_VERSION IREE_LLVM_VERSION IREE_HOST_ARCHIVE IREE_HOST_SHA256
  RISCV_TOOLCHAIN_ARCHIVE RISCV_TOOLCHAIN_SHA256 PHASE2_REPOSITORY_COMMIT
  PHASE2_RUNTIME_LINKAGE RISCV_READELF_RELATIVE RISCV_OBJDUMP_RELATIVE
)
for key in "${required_config_keys[@]}"; do
  [[ -n "${!key:-}" ]] || die "missing or empty configuration value: $key"
done
[[ "$SCHEMA_VERSION" == 1 ]] || die 'SCHEMA_VERSION must be 1'
[[ "$TARGET_TRIPLE" == riscv64 && "$TARGET_ABI" == lp64d ]] || die 'unexpected target triple or ABI'
[[ "$SCALAR_CPU_FEATURES" == '+m,+a,+f,+d,+c' ]] || die 'unexpected scalar feature contract'
[[ "$RVV_CPU_FEATURES" == '+m,+a,+f,+d,+c,+v,+zvl256b' ]] || die 'unexpected RVV feature contract'
[[ "$OPT_LEVEL" == O2 && "$EXECUTABLE_FORMAT" == embedded-elf && "$TENSOR_LENGTH" == 1024 ]] || die 'unexpected workload contract'
[[ "$PHASE2_RUNTIME_LINKAGE" == dynamic || "$PHASE2_RUNTIME_LINKAGE" == static ]] || die 'invalid Phase 2 runtime linkage'
[[ "$IREE_SOURCE_REVISION" == "$PHASE2_IREE_REVISION" ]] || die 'IREE source revision differs from Phase 2'
[[ "$IREE_HOST_ARCHIVE" == "$PHASE2_IREE_HOST_ARCHIVE" && "$IREE_HOST_SHA256" == "$PHASE2_IREE_HOST_SHA256" ]] || die 'IREE host dependency differs from Phase 2'
[[ "$RISCV_TOOLCHAIN_ARCHIVE" == "$PHASE2_RISCV_TOOLCHAIN_ARCHIVE" && "$RISCV_TOOLCHAIN_SHA256" == "$PHASE2_RISCV_TOOLCHAIN_SHA256" ]] || die 'RISC-V toolchain dependency differs from Phase 2'
[[ "$IREE_COMPILER_VERSION" == unknown && "$IREE_LLVM_VERSION" == 24.0.0git ]] || die 'unexpected compiler identity'

verify_dependency_marker() {
  local marker="$1" archive="$2" digest="$3" label="$4"
  [[ -f "$marker" ]] || die "missing $label dependency marker: $marker"
  local -a lines
  mapfile -t lines < "$marker"
  [[ "${#lines[@]}" -eq 2 && "${lines[0]}" == "archive=$archive" && "${lines[1]}" == "sha256=$digest" ]] ||
    die "$label dependency marker does not exactly match the configured archive and SHA-256: $marker"
}

sha256_of() {
  local digest ignored
  read -r digest ignored < <(sha256sum "$1")
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 output for $1"
  printf '%s' "$digest"
}

serialize_command() {
  local value
  printf -v value '%q ' "$@"
  [[ "$value" != *$'\n'* ]] || die 'serialized command contains a newline'
  printf '%s' "$value"
}

manifest_keys=(
  SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT IREE_COMPILER_VERSION
  IREE_LLVM_VERSION IREE_SOURCE_REVISION IREE_HOST_ARCHIVE IREE_HOST_SHA256
  RISCV_TOOLCHAIN_ARCHIVE RISCV_TOOLCHAIN_SHA256 TARGET_TRIPLE TARGET_ABI
  TARGET_CPU_FEATURES OPT_LEVEL HAL_TARGET_DEVICE HAL_TARGET_BACKEND
  EXECUTABLE_FORMAT UKERNELS INPUT_MLIR_SHA256 VMFB_SHA256
  DUMPS_SHA256_FILE_SHA256
)

parse_manifest() {
  local manifest="$1" destination_name="$2"
  shift 2
  local -a allowed=("$@")
  local -n destination="$destination_name"
  destination=()
  local line key value candidate known
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die "malformed manifest line in $manifest: $line"
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$value" != *$'\n'* ]] || die "malformed manifest entry in $manifest"
    known=false
    for candidate in "${allowed[@]}"; do [[ "$candidate" == "$key" ]] && known=true && break; done
    [[ "$known" == true ]] || die "unknown manifest key in $manifest: $key"
    [[ ! -v "destination[$key]" ]] || die "duplicate manifest key in $manifest: $key"
    destination["$key"]="$value"
  done < "$manifest"
  for candidate in "${allowed[@]}"; do [[ -v "destination[$candidate]" ]] || die "missing manifest key in $manifest: $candidate"; done
  [[ "${#destination[@]}" -eq "${#allowed[@]}" ]] || die "manifest key count mismatch: $manifest"
}

verify_dependency_marker "$HOST_MARKER" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" host
verify_dependency_marker "$TOOLCHAIN_MARKER" "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256" RISC-V-toolchain
[[ -x "$IREE_COMPILE" && -x "$IREE_RUN_MODULE" ]] || die 'prepared IREE executables are missing'
READELF="$TOOLCHAIN_DIR/$RISCV_READELF_RELATIVE"
OBJDUMP="$TOOLCHAIN_DIR/$RISCV_OBJDUMP_RELATIVE"
[[ -x "$READELF" && -x "$OBJDUMP" ]] || die 'configured target-prefixed ELF tools are missing'
SOURCE_HEAD="$(git -C "$IREE_SOURCE_DIR" rev-parse HEAD 2>/dev/null)" || die 'prepared IREE source is not a Git checkout'
[[ "$SOURCE_HEAD" == "$IREE_SOURCE_REVISION" ]] || die "IREE source mismatch: $SOURCE_HEAD"

CURRENT_COMMIT="$(git rev-parse HEAD)"
if [[ "$REVIEW" == true ]]; then
  ROOT=build/iree/rvv-validation/review
  BINDING=REVIEW_WORKTREE
else
  ROOT=build/iree/rvv-validation
  BINDING=PUSHED_COMMIT
  [[ -z "$(git status --porcelain)" ]] || die 'final mode requires a clean working tree'
  git fetch origin --prune --quiet
  git branch --remotes --contains "$CURRENT_COMMIT" | grep -q 'origin/' || die "commit $CURRENT_COMMIT is not pushed to origin"
fi
CONFIG_SHA256="$(sha256_of "$CONFIG")"
INPUT_SHA256="$(sha256_of "$SOURCE")"

check_existing_identity() {
  local directory="$1"
  local manifest="$directory/compile.manifest"
  [[ -e "$directory" ]] || return 0
  [[ -f "$manifest" ]] || die "existing output lacks an identity manifest; remove manually: $directory"
  declare -A old=()
  parse_manifest "$manifest" old "${manifest_keys[@]}"
  [[ "${old[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" && "${old[ARTIFACT_BINDING]}" == "$BINDING" && "${old[INPUT_MLIR_SHA256]}" == "$INPUT_SHA256" ]] ||
    die "existing evidence has another identity; remove manually: $directory"
}

compiler_version_check() {
  local output="$1"
  "$IREE_COMPILE" --version > "$output" 2>&1
  grep -F "IREE compiler version ($IREE_COMPILER_VERSION)" "$output" >/dev/null || die 'compiler version string mismatch'
  grep -F "LLVM version $IREE_LLVM_VERSION" "$output" >/dev/null || die 'LLVM version string mismatch'
}

common_compile_command() {
  local -n result="$1"
  local input="$2" output="$3" dumps="$4" features="$5" level="$6"
  result=(
    "$IREE_COMPILE" "$input"
    --iree-hal-target-device=local
    --iree-hal-local-target-device-backends=llvm-cpu
    "--iree-llvmcpu-target-triple=$TARGET_TRIPLE"
    "--iree-llvmcpu-target-abi=$TARGET_ABI"
    --iree-llvmcpu-link-embedded=true
    --iree-llvmcpu-enable-ukernels=none
    --iree-llvmcpu-enable-llvm-ukernels=
    --iree-llvmcpu-link-ukernel-bitcode=false
    "--iree-llvmcpu-target-cpu-features=$features"
    "--iree-opt-level=$level"
    "--iree-hal-dump-executable-files-to=$dumps"
    -o "$output"
  )
}

oracle_arguments() {
  local function_name="${1:-add_1024}" length="${2:-1024}"
  ORACLE_ARGS=(
    "--function=$function_name"
    "--input=${length}xf32=1"
    "--input=${length}xf32=2"
    "--expected_output=${length}xf32=3"
  )
}

write_dump_hashes() {
  local dump_dir="$1" list="$2"
  local -a files=()
  local file
  shopt -s nullglob
  for file in "$dump_dir"/*; do [[ -f "$file" ]] && files+=("$file"); done
  shopt -u nullglob
  [[ "${#files[@]}" -gt 0 ]] || die "dump directory is empty: $dump_dir"
  : > "$list"
  while IFS= read -r file; do
    local digest
    digest="$(sha256_of "$file")"
    printf '%s  %s\n' "$digest" "$(basename "$file")" >> "$list"
  done < <(printf '%s\n' "${files[@]}" | sort)
  (cd "$dump_dir" && sha256sum --check "../$(basename "$list")")
}

require_dump_classes() {
  local dump_dir="$1" pattern
  local patterns=('*.mlir' '*.codegen.ll' '*.codegen.bc' '*.linked.ll' '*.linked.bc' '*.optimized.ll' '*.optimized.bc' '*.s' '*.o' '*.so')
  for pattern in "${patterns[@]}"; do
    compgen -G "$dump_dir/$pattern" >/dev/null || die "missing required dump class $pattern in $dump_dir"
  done
}

write_manifest() {
  local directory="$1" features="$2" level="$3" input_hash="$4" vmfb="$5"
  local manifest="$directory/compile.manifest"
  local vmfb_hash dumps_list_hash
  vmfb_hash="$(sha256_of "$vmfb")"
  dumps_list_hash="$(sha256_of "$directory/dumps.sha256")"
  printf '%s\n' \
    "SCHEMA_VERSION=$SCHEMA_VERSION" \
    "ARTIFACT_BINDING=$BINDING" \
    "REPOSITORY_COMMIT=$CURRENT_COMMIT" \
    "IREE_COMPILER_VERSION=$IREE_COMPILER_VERSION" \
    "IREE_LLVM_VERSION=$IREE_LLVM_VERSION" \
    "IREE_SOURCE_REVISION=$IREE_SOURCE_REVISION" \
    "IREE_HOST_ARCHIVE=$IREE_HOST_ARCHIVE" \
    "IREE_HOST_SHA256=$IREE_HOST_SHA256" \
    "RISCV_TOOLCHAIN_ARCHIVE=$RISCV_TOOLCHAIN_ARCHIVE" \
    "RISCV_TOOLCHAIN_SHA256=$RISCV_TOOLCHAIN_SHA256" \
    "TARGET_TRIPLE=$TARGET_TRIPLE" \
    "TARGET_ABI=$TARGET_ABI" \
    "TARGET_CPU_FEATURES=$features" \
    "OPT_LEVEL=$level" \
    'HAL_TARGET_DEVICE=local' \
    'HAL_TARGET_BACKEND=llvm-cpu' \
    "EXECUTABLE_FORMAT=$EXECUTABLE_FORMAT" \
    'UKERNELS=disabled' \
    "INPUT_MLIR_SHA256=$input_hash" \
    "VMFB_SHA256=$vmfb_hash" \
    "DUMPS_SHA256_FILE_SHA256=$dumps_list_hash" > "$manifest"
  declare -A parsed=()
  parse_manifest "$manifest" parsed "${manifest_keys[@]}"
  [[ "${parsed[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" && "${parsed[ARTIFACT_BINDING]}" == "$BINDING" && "${parsed[INPUT_MLIR_SHA256]}" == "$input_hash" && "${parsed[VMFB_SHA256]}" == "$vmfb_hash" ]] || die "manifest validation failed: $manifest"
}

compile_variant() {
  local directory="$1" basename="$2" features="$3" level="$4" input="$5" input_hash="$6"
  mkdir -p "$directory/dumps"
  local vmfb="$directory/$basename"
  local sidecar="$directory/$basename.sha256"
  local -a command=()
  common_compile_command command "$input" "$vmfb" "$directory/dumps" "$features" "$level"
  "${command[@]}"
  [[ -s "$vmfb" ]] || die "compiler produced no VMFB: $vmfb"
  require_dump_classes "$directory/dumps"
  write_dump_hashes "$directory/dumps" "$directory/dumps.sha256"
  local vmfb_hash
  vmfb_hash="$(sha256_of "$vmfb")"
  printf '%s  %s\n' "$vmfb_hash" "$basename" > "$sidecar"
  (cd "$directory" && sha256sum --check "$(basename "$sidecar")")
  write_manifest "$directory" "$features" "$level" "$input_hash" "$vmfb"
}

validate_primary_result_b() {
  local inspection="$ROOT/inspection/inspection.manifest"
  [[ -f "$inspection" ]] || die 'diagnostics require a completed primary inspection'
  grep -Fx 'INSPECTION_RESULT=RESULT_B_NO_RVV' "$inspection" >/dev/null || die 'diagnostics are allowed only after RESULT_B_NO_RVV'
  for variant in scalar rvv; do [[ -f "$ROOT/$variant/compile.manifest" ]] || die "missing primary $variant manifest"; done
}

compile_diagnostic() {
  validate_primary_result_b
  local diag_root="$ROOT/diagnostics/$DIAGNOSTIC"
  [[ ! -e "$diag_root" ]] || die "remove existing diagnostic output manually before rerun: $diag_root"
  mkdir -p "$diag_root"
  local input="$SOURCE" input_hash="$INPUT_SHA256" level=O3 function_name=add_1024 length=1024
  if [[ "$DIAGNOSTIC" == length-4096 ]]; then
    level=O2; function_name=add_4096; length=4096; input="$diag_root/tensor_add_4096.mlir"
    cat > "$input" <<'MLIR'
module {
  func.func @add_4096(
      %lhs: tensor<4096xf32>,
      %rhs: tensor<4096xf32>
  ) -> tensor<4096xf32> attributes {iree.module.export} {
    %sum = arith.addf %lhs, %rhs : tensor<4096xf32>
    return %sum : tensor<4096xf32>
  }
}
MLIR
    input_hash="$(sha256_of "$input")"
    mkdir -p "$diag_root/host"
    local host_vmfb="$diag_root/host/tensor_add_host.vmfb"
    local -a host_command=("$IREE_COMPILE" "$input" --iree-hal-target-device=local --iree-hal-local-target-device-backends=llvm-cpu --iree-llvmcpu-target-cpu=host --iree-opt-level=O2 -o "$host_vmfb")
    "${host_command[@]}"
    oracle_arguments "$function_name" "$length"
    set +e
    "$IREE_RUN_MODULE" --device=local-task "--module=$host_vmfb" "${ORACLE_ARGS[@]}" 2>&1 | tee "$diag_root/host/correctness.txt"
    local run_status="${PIPESTATUS[0]}"
    set -e
    [[ "$run_status" -eq 0 ]] || die 'length-4096 host oracle failed'
    [[ "$(grep -Fc '[SUCCESS] all function outputs matched their expected values.' "$diag_root/host/correctness.txt")" -eq 1 ]] || die 'length-4096 host success line mismatch'
  fi
  compile_variant "$diag_root/rvv" tensor_add_rvv.vmfb "$RVV_CPU_FEATURES" "$level" "$input" "$input_hash"
  printf 'DIAGNOSTIC_KIND=%s\nPRIMARY_INSPECTION_RESULT=RESULT_B_NO_RVV\n' "$DIAGNOSTIC" > "$diag_root/diagnostic.context"
}

if [[ -n "$DIAGNOSTIC" ]]; then
  compile_diagnostic
  printf 'Diagnostic compilation complete: %s\n' "$ROOT/diagnostics/$DIAGNOSTIC"
  exit 0
fi

for variant in scalar rvv; do check_existing_identity "$ROOT/$variant"; done
mkdir -p "$ROOT"
PREFLIGHT_TMP="$ROOT/preflight.tmp.$$"
HOST_TMP="$ROOT/host.tmp.$$"
SCALAR_TMP="$ROOT/scalar.tmp.$$"
RVV_TMP="$ROOT/rvv.tmp.$$"
trap 'rm -rf -- "${PREFLIGHT_TMP:-}" "${HOST_TMP:-}" "${SCALAR_TMP:-}" "${RVV_TMP:-}"' EXIT
mkdir -p "$PREFLIGHT_TMP" "$HOST_TMP" "$SCALAR_TMP" "$RVV_TMP"
compiler_version_check "$PREFLIGHT_TMP/compiler-version.txt"
local_probe_dumps="$PREFLIGHT_TMP/probe-dumps"
mkdir -p "$local_probe_dumps"
probe_command=()
common_compile_command probe_command "$PHASE2_SOURCE" /dev/null "$local_probe_dumps" "$RVV_CPU_FEATURES" "$OPT_LEVEL"
printf '%s\n' "$(serialize_command "${probe_command[@]}")" > "$PREFLIGHT_TMP/rvv-feature-command.txt"
set +e
"${probe_command[@]}" > "$PREFLIGHT_TMP/rvv-feature-probe.txt" 2>&1
probe_status="$?"
set -e
rm -rf "$local_probe_dumps"
if [[ "$probe_status" -ne 0 ]]; then
  rm -rf "$ROOT/preflight"
  mv "$PREFLIGHT_TMP" "$ROOT/preflight"
  PREFLIGHT_TMP=''
  printf 'RESULT_D: the pinned compiler rejected %s\n' "$RVV_CPU_FEATURES" >&2
  exit 1
fi

host_vmfb="$HOST_TMP/tensor_add_host.vmfb"
host_compile=("$IREE_COMPILE" "$SOURCE" --iree-hal-target-device=local --iree-hal-local-target-device-backends=llvm-cpu --iree-llvmcpu-target-cpu=host "--iree-opt-level=$OPT_LEVEL" -o "$host_vmfb")
"${host_compile[@]}"
[[ -s "$host_vmfb" ]] || die 'host compiler produced no VMFB'
oracle_arguments add_1024 1024
set +e
"$IREE_RUN_MODULE" --device=local-task "--module=$host_vmfb" "${ORACLE_ARGS[@]}" 2>&1 | tee "$HOST_TMP/correctness.txt"
host_status="${PIPESTATUS[0]}"
set -e
if [[ "$host_status" -ne 0 || "$(grep -Fc '[SUCCESS] all function outputs matched their expected values.' "$HOST_TMP/correctness.txt")" -ne 1 ]]; then
  rm -rf "$ROOT/host"
  mv "$HOST_TMP" "$ROOT/host"
  HOST_TMP=''
  rm -rf "$SCALAR_TMP" "$RVV_TMP"
  die 'host correctness oracle failed'
fi

compile_variant "$SCALAR_TMP" tensor_add_scalar.vmfb "$SCALAR_CPU_FEATURES" "$OPT_LEVEL" "$SOURCE" "$INPUT_SHA256"
compile_variant "$RVV_TMP" tensor_add_rvv.vmfb "$RVV_CPU_FEATURES" "$OPT_LEVEL" "$SOURCE" "$INPUT_SHA256"

rm -rf "$ROOT/preflight" "$ROOT/host" "$ROOT/scalar" "$ROOT/rvv"
mv "$PREFLIGHT_TMP" "$ROOT/preflight"; PREFLIGHT_TMP=''
mv "$HOST_TMP" "$ROOT/host"; HOST_TMP=''
mv "$SCALAR_TMP" "$ROOT/scalar"; SCALAR_TMP=''
mv "$RVV_TMP" "$ROOT/rvv"; RVV_TMP=''
trap - EXIT
printf 'Variant compilation complete: %s\n' "$ROOT"
