#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf 'Usage: run_rvv_compare_on_board.sh\nEnvironment:\n  BOARD_HOST=<ssh host> (default: orangepi-rv2)\n' >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 0 ]] || { usage; exit 2; }
for command_name in git ssh scp grep sha256sum tee file cp mkdir rm; do
  command -v "$command_name" >/dev/null 2>&1 || die "required local command not found: $command_name"
done
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'run from inside the repository'
cd "$REPO_ROOT"
BOARD_HOST="${BOARD_HOST:-orangepi-rv2}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10)
PHASE2_CONFIG=scripts/iree/iree.env
CONFIG=scripts/iree/rvv.env
PHASE2_RECORD=docs/rvv/iree-scalar-validation.md
SOURCE=src/iree/tensor_add_rvv.mlir
ROOT=build/iree/rvv-validation
BOARD_DIR="$ROOT/board"
SCALAR_DIR="$ROOT/scalar"
RVV_DIR="$ROOT/rvv"
INSPECTION_DIR="$ROOT/inspection"
DEPS=build/iree/deps
HOST_MARKER="$DEPS/iree-host/.iree-dependency"
TOOLCHAIN_MARKER="$DEPS/riscv-toolchain/.iree-dependency"
[[ -f "$PHASE2_CONFIG" && -f "$CONFIG" && -f "$PHASE2_RECORD" && -f "$SOURCE" ]] || die 'missing tracked validation input'
# shellcheck source=/dev/null
. "$PHASE2_CONFIG"
PHASE2_IREE_REVISION="$IREE_REVISION"
PHASE2_IREE_HOST_ARCHIVE="$IREE_HOST_ARCHIVE"
PHASE2_IREE_HOST_SHA256="$IREE_HOST_SHA256"
PHASE2_RISCV_TOOLCHAIN_ARCHIVE="$RISCV_TOOLCHAIN_ARCHIVE"
PHASE2_RISCV_TOOLCHAIN_SHA256="$RISCV_TOOLCHAIN_SHA256"
# shellcheck source=/dev/null
. "$CONFIG"

[[ "$SCHEMA_VERSION" == 1 && "$TARGET_TRIPLE" == riscv64 && "$TARGET_ABI" == lp64d ]] || die 'invalid target contract'
[[ "$SCALAR_CPU_FEATURES" == '+m,+a,+f,+d,+c' && "$RVV_CPU_FEATURES" == '+m,+a,+f,+d,+c,+v,+zvl256b' ]] || die 'invalid feature contract'
[[ "$OPT_LEVEL" == O2 && "$EXECUTABLE_FORMAT" == embedded-elf && "$TENSOR_LENGTH" == 1024 ]] || die 'invalid workload contract'
[[ "$IREE_SOURCE_REVISION" == "$PHASE2_IREE_REVISION" && "$IREE_HOST_ARCHIVE" == "$PHASE2_IREE_HOST_ARCHIVE" && "$IREE_HOST_SHA256" == "$PHASE2_IREE_HOST_SHA256" ]] || die 'IREE identity differs from Phase 2'
[[ "$RISCV_TOOLCHAIN_ARCHIVE" == "$PHASE2_RISCV_TOOLCHAIN_ARCHIVE" && "$RISCV_TOOLCHAIN_SHA256" == "$PHASE2_RISCV_TOOLCHAIN_SHA256" ]] || die 'toolchain identity differs from Phase 2'
[[ "$PHASE2_RUNTIME_LINKAGE" == dynamic || "$PHASE2_RUNTIME_LINKAGE" == static ]] || die 'invalid Phase 2 runtime linkage'

grep -F "Repository commit: \`$PHASE2_REPOSITORY_COMMIT\`" "$PHASE2_RECORD" >/dev/null || die 'scalar validation record commit mismatch'
grep -F "accepted runtime linkage is \`$PHASE2_RUNTIME_LINKAGE\`" "$PHASE2_RECORD" >/dev/null || die 'scalar validation record linkage mismatch'

verify_dependency_marker() {
  local marker="$1" archive="$2" digest="$3" label="$4"
  [[ -f "$marker" ]] || die "missing $label marker: $marker"
  local -a lines
  mapfile -t lines < "$marker"
  [[ "${#lines[@]}" -eq 2 && "${lines[0]}" == "archive=$archive" && "${lines[1]}" == "sha256=$digest" ]] || die "$label marker mismatch"
}
sha256_of() {
  local digest ignored
  read -r digest ignored < <(sha256sum "$1")
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 output for $1"
  printf '%s' "$digest"
}
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
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "malformed key in $manifest: $key"
    known=false
    for candidate in "${allowed[@]}"; do [[ "$candidate" == "$key" ]] && known=true && break; done
    [[ "$known" == true ]] || die "unknown key in $manifest: $key"
    [[ ! -v "destination[$key]" ]] || die "duplicate key in $manifest: $key"
    destination["$key"]="$value"
  done < "$manifest"
  for candidate in "${allowed[@]}"; do [[ -v "destination[$candidate]" ]] || die "missing key in $manifest: $candidate"; done
  [[ "${#destination[@]}" -eq "${#allowed[@]}" ]] || die "manifest key count mismatch: $manifest"
}
verify_sidecar() {
  local file="$1" sidecar="$2" expected_name="$3" digest line
  digest="$(sha256_of "$file")"
  mapfile -t lines < "$sidecar"
  [[ "${#lines[@]}" -eq 1 && "${lines[0]}" == "$digest  $expected_name" ]] || die "sidecar mismatch: $sidecar"
}
verify_dependency_marker "$HOST_MARKER" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" host
verify_dependency_marker "$TOOLCHAIN_MARKER" "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256" RISC-V-toolchain

CURRENT_COMMIT="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain)" ]] || die 'board execution requires a clean working tree'
git fetch origin --prune --quiet
git branch --remotes --contains "$CURRENT_COMMIT" | grep -q 'origin/' || die "commit $CURRENT_COMMIT is not pushed"

compile_keys=(
  SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT IREE_COMPILER_VERSION IREE_LLVM_VERSION
  IREE_SOURCE_REVISION IREE_HOST_ARCHIVE IREE_HOST_SHA256 RISCV_TOOLCHAIN_ARCHIVE
  RISCV_TOOLCHAIN_SHA256 TARGET_TRIPLE TARGET_ABI TARGET_CPU_FEATURES OPT_LEVEL
  HAL_TARGET_DEVICE HAL_TARGET_BACKEND EXECUTABLE_FORMAT UKERNELS INPUT_MLIR_SHA256
  VMFB_SHA256 DUMPS_SHA256_FILE_SHA256
)
inspection_keys=(
  SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT SCALAR_COMPILE_MANIFEST_SHA256
  RVV_COMPILE_MANIFEST_SHA256 SCALAR_VMFB_SHA256 RVV_VMFB_SHA256 SCALAR_PAYLOAD_PATH
  SCALAR_PAYLOAD_SHA256 RVV_PAYLOAD_PATH RVV_PAYLOAD_SHA256 READELF_PATH READELF_VERSION
  OBJDUMP_PATH OBJDUMP_VERSION SCALAR_CONFIG_COUNT SCALAR_DATA_COUNT SCALAR_TOTAL_COUNT
  RVV_CONFIG_COUNT RVV_DATA_COUNT RVV_TOTAL_COUNT ATTRIBUTE_STATUS INSPECTION_RESULT
)
SCALAR_VMFB="$SCALAR_DIR/tensor_add_scalar.vmfb"
RVV_VMFB="$RVV_DIR/tensor_add_rvv.vmfb"
for required in "$SCALAR_DIR/compile.manifest" "$RVV_DIR/compile.manifest" "$SCALAR_VMFB" "$SCALAR_VMFB.sha256" "$RVV_VMFB" "$RVV_VMFB.sha256" "$SCALAR_DIR/dumps.sha256" "$RVV_DIR/dumps.sha256" "$INSPECTION_DIR/inspection.manifest" "$INSPECTION_DIR/inspection-summary.txt"; do
  [[ -f "$required" ]] || die "missing final evidence: $required"
done
declare -A scalar=() rvv=() inspection=()
parse_manifest "$SCALAR_DIR/compile.manifest" scalar "${compile_keys[@]}"
parse_manifest "$RVV_DIR/compile.manifest" rvv "${compile_keys[@]}"
parse_manifest "$INSPECTION_DIR/inspection.manifest" inspection "${inspection_keys[@]}"
for values_name in scalar rvv; do
  declare -n values_ref="$values_name"
  [[ "${values_ref[ARTIFACT_BINDING]}" == PUSHED_COMMIT && "${values_ref[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" ]] ||
    die "$values_name artifact binding mismatch"
  unset -n values_ref
done
[[ "${scalar[TARGET_CPU_FEATURES]}" == "$SCALAR_CPU_FEATURES" && "${rvv[TARGET_CPU_FEATURES]}" == "$RVV_CPU_FEATURES" ]] || die 'variant feature mismatch'
[[ "${inspection[ARTIFACT_BINDING]}" == PUSHED_COMMIT && "${inspection[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" && "${inspection[INSPECTION_RESULT]}" == PASS ]] || die 'inspection does not authorize board execution'
[[ "${inspection[SCALAR_CONFIG_COUNT]}" -eq 0 && "${inspection[SCALAR_DATA_COUNT]}" -eq 0 && "${inspection[RVV_CONFIG_COUNT]}" -ge 1 && "${inspection[RVV_DATA_COUNT]}" -ge 1 ]] || die 'inspection counts do not satisfy the experiment'
[[ "${inspection[SCALAR_COMPILE_MANIFEST_SHA256]}" == "$(sha256_of "$SCALAR_DIR/compile.manifest")" && "${inspection[RVV_COMPILE_MANIFEST_SHA256]}" == "$(sha256_of "$RVV_DIR/compile.manifest")" ]] || die 'inspection compile-manifest hashes mismatch'
verify_sidecar "$SCALAR_VMFB" "$SCALAR_VMFB.sha256" tensor_add_scalar.vmfb
verify_sidecar "$RVV_VMFB" "$RVV_VMFB.sha256" tensor_add_rvv.vmfb
[[ "${scalar[VMFB_SHA256]}" == "$(sha256_of "$SCALAR_VMFB")" && "${rvv[VMFB_SHA256]}" == "$(sha256_of "$RVV_VMFB")" ]] || die 'VMFB manifest hash mismatch'
(cd "$SCALAR_DIR/dumps" && sha256sum --check ../dumps.sha256 >/dev/null)
(cd "$RVV_DIR/dumps" && sha256sum --check ../dumps.sha256 >/dev/null)
[[ -f "${inspection[SCALAR_PAYLOAD_PATH]}" && -f "${inspection[RVV_PAYLOAD_PATH]}" ]] || die 'inspected payload is missing'
[[ "${inspection[SCALAR_PAYLOAD_SHA256]}" == "$(sha256_of "${inspection[SCALAR_PAYLOAD_PATH]}")" && "${inspection[RVV_PAYLOAD_SHA256]}" == "$(sha256_of "${inspection[RVV_PAYLOAD_PATH]}")" ]] || die 'payload hash mismatch'

PHASE2_COMPILE_MANIFEST=build/iree/compile-manifest.txt
TOOLCHAIN_VERSIONS=build/iree/toolchain-versions.txt
case "$PHASE2_RUNTIME_LINKAGE" in
  dynamic) PHASE2_BUILD=build/iree/runtime-riscv64; PHASE2_RUNTIME_MANIFEST=build/iree/runtime-manifest.txt ;;
  static) PHASE2_BUILD=build/iree/runtime-riscv64-static; PHASE2_RUNTIME_MANIFEST=build/iree/runtime-manifest-static.txt ;;
esac
RUNNER="$PHASE2_BUILD/tools/iree-run-module"
RUNNER_SIDECAR="$PHASE2_BUILD/iree-run-module.sha256"
for required in "$PHASE2_COMPILE_MANIFEST" "$PHASE2_RUNTIME_MANIFEST" "$TOOLCHAIN_VERSIONS" "$RUNNER" "$RUNNER_SIDECAR"; do [[ -f "$required" ]] || die "missing Phase 2 evidence: $required"; done
phase2_compile_keys=(REPOSITORY_COMMIT IREE_REVISION CONFIG_SHA256 SOURCE_SHA256 HOST_COMMAND SCALAR_COMMAND HOST_VMFB_SHA256 SCALAR_VMFB_SHA256)
phase2_runtime_keys=(REPOSITORY_COMMIT IREE_REVISION RUNTIME_LINKAGE CONFIG_SHA256 SOURCE_SHA256 COMPILE_MANIFEST_SHA256 CONFIGURE_COMMAND BUILD_COMMAND RUNNER_SHA256)
declare -A phase2_compile=() phase2_runtime=()
parse_manifest "$PHASE2_COMPILE_MANIFEST" phase2_compile "${phase2_compile_keys[@]}"
parse_manifest "$PHASE2_RUNTIME_MANIFEST" phase2_runtime "${phase2_runtime_keys[@]}"
[[ "${phase2_compile[REPOSITORY_COMMIT]}" == "$PHASE2_REPOSITORY_COMMIT" && "${phase2_runtime[REPOSITORY_COMMIT]}" == "$PHASE2_REPOSITORY_COMMIT" ]] || die 'Phase 2 manifest commit mismatch'
[[ "${phase2_runtime[IREE_REVISION]}" == "$IREE_SOURCE_REVISION" && "${phase2_runtime[RUNTIME_LINKAGE]}" == "$PHASE2_RUNTIME_LINKAGE" ]] || die 'Phase 2 runtime identity mismatch'
[[ "${phase2_runtime[COMPILE_MANIFEST_SHA256]}" == "$(sha256_of "$PHASE2_COMPILE_MANIFEST")" ]] || die 'Phase 2 compile-manifest hash mismatch'
for option in -DIREE_UK_BUILD_RISCV_64_V=OFF -DIREE_UK_BUILD_RISCV_64_ZVFH=OFF -DIREE_UK_BUILD_RISCV_64_ZVFHMIN=OFF; do [[ "${phase2_runtime[CONFIGURE_COMMAND]}" == *"$option"* ]] || die "Phase 2 runtime did not disable $option"; done
RUNNER_SHA256="$(sha256_of "$RUNNER")"
[[ "${phase2_runtime[RUNNER_SHA256]}" == "$RUNNER_SHA256" ]] || die 'Phase 2 runner hash mismatch'
verify_sidecar "$RUNNER" "$RUNNER_SIDECAR" iree-run-module
RUNNER_FILE="$(file "$RUNNER")"
[[ "$RUNNER_FILE" == *'ELF 64-bit LSB'* && "$RUNNER_FILE" == *'UCB RISC-V'* && "$RUNNER_FILE" == *'double-float ABI'* ]] || die 'Phase 2 runner ELF identity mismatch'
RUNNER_ATTRIBUTES="$PHASE2_BUILD/iree-run-module.readelf-A.txt"
[[ -f "$RUNNER_ATTRIBUTES" ]] || die 'missing Phase 2 runner attributes'
if grep -E 'Tag_RISCV_arch:.*(_v[0-9]|_zve|_zvl)' "$RUNNER_ATTRIBUTES" >/dev/null; then die 'Phase 2 runner has vector ISA attributes'; fi

mkdir -p "$BOARD_DIR"
STAGING="$BOARD_DIR/transfer"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$RUNNER" "$STAGING/iree-run-module"
cp "$RUNNER_SIDECAR" "$STAGING/iree-run-module.sha256"
cp "$PHASE2_COMPILE_MANIFEST" "$STAGING/phase2.compile.manifest"
cp "$PHASE2_RUNTIME_MANIFEST" "$STAGING/phase2.runtime.manifest"
cp "$TOOLCHAIN_VERSIONS" "$STAGING/toolchain-versions.txt"
cp "$SCALAR_VMFB" "$STAGING/tensor_add_scalar.vmfb"
cp "$SCALAR_VMFB.sha256" "$STAGING/tensor_add_scalar.vmfb.sha256"
cp "$RVV_VMFB" "$STAGING/tensor_add_rvv.vmfb"
cp "$RVV_VMFB.sha256" "$STAGING/tensor_add_rvv.vmfb.sha256"
cp "$SCALAR_DIR/compile.manifest" "$STAGING/scalar.compile.manifest"
cp "$RVV_DIR/compile.manifest" "$STAGING/rvv.compile.manifest"
cp "$INSPECTION_DIR/inspection.manifest" "$STAGING/inspection.manifest"
(
  cd "$STAGING"
  sha256sum iree-run-module iree-run-module.sha256 phase2.compile.manifest phase2.runtime.manifest toolchain-versions.txt tensor_add_scalar.vmfb tensor_add_scalar.vmfb.sha256 tensor_add_rvv.vmfb tensor_add_rvv.vmfb.sha256 scalar.compile.manifest rvv.compile.manifest inspection.manifest > transfer.sha256
  sha256sum --check transfer.sha256 >/dev/null
)

REMOTE_DIR=''
BOARD_ARCH='unknown'
PREFLIGHT_RESULT=NOT_RUN
SCALAR_RUN_1_RESULT=NOT_RUN
RVV_RUN_1_RESULT=NOT_RUN
SCALAR_RUN_2_RESULT=NOT_RUN
RVV_RUN_2_RESULT=NOT_RUN
CLEANUP_RESULT=NOT_RUN
remote_output="$(ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" 'mktemp -d /tmp/rvv-iree-lab-rvv.XXXXXX' 2>&1)" || die "remote mktemp failed: $remote_output"
[[ "$remote_output" != *$'\n'* && "$remote_output" =~ ^/tmp/rvv-iree-lab-rvv\.[A-Za-z0-9]+$ ]] || die "unsafe remote path: $remote_output"
REMOTE_DIR="$remote_output"

write_board_manifest() {
  local result="$1"
  local preflight_hash=NOT_AVAILABLE scalar1_hash=NOT_AVAILABLE rvv1_hash=NOT_AVAILABLE scalar2_hash=NOT_AVAILABLE rvv2_hash=NOT_AVAILABLE
  [[ -f "$BOARD_DIR/preflight.txt" ]] && preflight_hash="$(sha256_of "$BOARD_DIR/preflight.txt")"
  [[ -f "$BOARD_DIR/scalar-run-1.txt" ]] && scalar1_hash="$(sha256_of "$BOARD_DIR/scalar-run-1.txt")"
  [[ -f "$BOARD_DIR/rvv-run-1.txt" ]] && rvv1_hash="$(sha256_of "$BOARD_DIR/rvv-run-1.txt")"
  [[ -f "$BOARD_DIR/scalar-run-2.txt" ]] && scalar2_hash="$(sha256_of "$BOARD_DIR/scalar-run-2.txt")"
  [[ -f "$BOARD_DIR/rvv-run-2.txt" ]] && rvv2_hash="$(sha256_of "$BOARD_DIR/rvv-run-2.txt")"
  printf '%s\n' \
    "SCHEMA_VERSION=$SCHEMA_VERSION" "REPOSITORY_COMMIT=$CURRENT_COMMIT" \
    "PHASE2_REPOSITORY_COMMIT=$PHASE2_REPOSITORY_COMMIT" "PHASE2_RUNTIME_LINKAGE=$PHASE2_RUNTIME_LINKAGE" "RUNNER_SHA256=$RUNNER_SHA256" \
    "SCALAR_VMFB_SHA256=${scalar[VMFB_SHA256]}" "RVV_VMFB_SHA256=${rvv[VMFB_SHA256]}" \
    "SCALAR_PAYLOAD_SHA256=${inspection[SCALAR_PAYLOAD_SHA256]}" "RVV_PAYLOAD_SHA256=${inspection[RVV_PAYLOAD_SHA256]}" \
    "BOARD_HOST=$BOARD_HOST" "BOARD_ARCH=$BOARD_ARCH" "PREFLIGHT_SHA256=$preflight_hash" \
    "SCALAR_RUN_1_SHA256=$scalar1_hash" "RVV_RUN_1_SHA256=$rvv1_hash" "SCALAR_RUN_2_SHA256=$scalar2_hash" "RVV_RUN_2_SHA256=$rvv2_hash" \
    "PREFLIGHT_RESULT=$PREFLIGHT_RESULT" "SCALAR_RUN_1_RESULT=$SCALAR_RUN_1_RESULT" "RVV_RUN_1_RESULT=$RVV_RUN_1_RESULT" "SCALAR_RUN_2_RESULT=$SCALAR_RUN_2_RESULT" "RVV_RUN_2_RESULT=$RVV_RUN_2_RESULT" \
    "CLEANUP_RESULT=$CLEANUP_RESULT" "BOARD_RESULT=$result" > "$BOARD_DIR/board.manifest"
  grep -Fx "BOARD_RESULT=$result" "$BOARD_DIR/board.manifest" >/dev/null || return 1
}

finalize() {
  local primary_status="$?"
  trap - EXIT
  if [[ -n "$REMOTE_DIR" && "$REMOTE_DIR" =~ ^/tmp/rvv-iree-lab-rvv\.[A-Za-z0-9]+$ ]]; then
    if ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- "$REMOTE_DIR" <<'REMOTE_CLEANUP'
set -Eeuo pipefail
remote_dir="$1"
[[ "$remote_dir" =~ ^/tmp/rvv-iree-lab-rvv\.[A-Za-z0-9]+$ ]]
rm -rf -- "$remote_dir"
REMOTE_CLEANUP
    then CLEANUP_RESULT=PASS; else CLEANUP_RESULT=FAIL; primary_status=1; fi
  else CLEANUP_RESULT=FAIL; primary_status=1; fi
  local board_result=FAIL
  if [[ "$primary_status" -eq 0 && "$PREFLIGHT_RESULT" == PASS && "$SCALAR_RUN_1_RESULT" == PASS && "$RVV_RUN_1_RESULT" == PASS && "$SCALAR_RUN_2_RESULT" == PASS && "$RVV_RUN_2_RESULT" == PASS && "$CLEANUP_RESULT" == PASS ]]; then board_result=PASS; fi
  write_board_manifest "$board_result" || primary_status=1
  exit "$primary_status"
}
trap finalize EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

scp "${SSH_OPTIONS[@]}" "$STAGING"/* "$BOARD_HOST:$REMOTE_DIR/"
set +e
ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- "$REMOTE_DIR" "$PHASE2_RUNTIME_LINKAGE" 2>&1 <<'REMOTE_PREFLIGHT' | tee "$BOARD_DIR/preflight.txt"
set -Eeuo pipefail
remote_dir="$1"; linkage="$2"
cd "$remote_dir"
sha256sum --check transfer.sha256
chmod 0755 iree-run-module
arch="$(uname -m)"; printf 'BOARD_ARCH=%s\n' "$arch"; [[ "$arch" == riscv64 ]]
runner_file="$(file ./iree-run-module)"; printf 'RUNNER_FILE=%s\n' "$runner_file"
[[ "$runner_file" == *'ELF 64-bit LSB'* && "$runner_file" == *'UCB RISC-V'* ]]
if [[ "$linkage" == dynamic ]]; then
  ldd_output="$(ldd ./iree-run-module 2>&1)"; printf '%s\n' "$ldd_output"; [[ "$ldd_output" != *'not found'* ]]
else
  [[ "$runner_file" == *'statically linked'* ]]
fi
REMOTE_PREFLIGHT
preflight_status="${PIPESTATUS[0]}"
set -e
[[ "$preflight_status" -eq 0 ]] || die 'board preflight failed'
BOARD_ARCH="$(grep -E '^BOARD_ARCH=' "$BOARD_DIR/preflight.txt" | awk -F= 'NR==1 {print $2}')"
[[ "$BOARD_ARCH" == riscv64 ]] || die 'board preflight architecture mismatch'
PREFLIGHT_RESULT=PASS

run_remote_variant() {
  local label="$1" vmfb="$2" result_name="$3"
  local log="$BOARD_DIR/$label.txt"
  set +e
  ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- "$REMOTE_DIR" "$vmfb" 2>&1 <<'REMOTE_RUN' | tee "$log"
set -Eeuo pipefail
cd "$1"
./iree-run-module --device=local-task "--module=$2" --function=add_1024 --input=1024xf32=1 --input=1024xf32=2 --expected_output=1024xf32=3
REMOTE_RUN
  local status="${PIPESTATUS[0]}"
  set -e
  [[ "$status" -eq 0 ]] || die "$label failed with status $status"
  [[ "$(grep -Fc '[SUCCESS] all function outputs matched their expected values.' "$log")" -eq 1 ]] || die "$label success-line count mismatch"
  printf -v "$result_name" PASS
}
run_remote_variant scalar-run-1 tensor_add_scalar.vmfb SCALAR_RUN_1_RESULT
run_remote_variant rvv-run-1 tensor_add_rvv.vmfb RVV_RUN_1_RESULT
run_remote_variant scalar-run-2 tensor_add_scalar.vmfb SCALAR_RUN_2_RESULT
run_remote_variant rvv-run-2 tensor_add_rvv.vmfb RVV_RUN_2_RESULT
printf 'Board comparison passed; cleanup and manifest finalization pending.\n'
