#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf 'Usage: inspect_payloads.sh [--review] [--diagnostic=length-4096|o3]\n' >&2
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

for command_name in git awk grep mkdir sha256sum sort; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'run from inside the repository'
cd "$REPO_ROOT"
CONFIG=scripts/iree/rvv.env
SOURCE=src/iree/tensor_add_rvv.mlir
PHASE2_CONFIG=scripts/iree/iree.env
DEPS=build/iree/deps
HOST_MARKER="$DEPS/iree-host/.iree-dependency"
TOOLCHAIN_MARKER="$DEPS/riscv-toolchain/.iree-dependency"
TOOLCHAIN_DIR="$DEPS/riscv-toolchain"
[[ -f "$CONFIG" && -f "$SOURCE" && -f "$PHASE2_CONFIG" ]] || die 'missing tracked Phase 2/3 inputs'
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
[[ "$IREE_SOURCE_REVISION" == "$PHASE2_IREE_REVISION" ]] || die 'IREE revision differs from Phase 2'
[[ "$IREE_HOST_ARCHIVE" == "$PHASE2_IREE_HOST_ARCHIVE" && "$IREE_HOST_SHA256" == "$PHASE2_IREE_HOST_SHA256" ]] || die 'IREE host dependency differs from Phase 2'
[[ "$RISCV_TOOLCHAIN_ARCHIVE" == "$PHASE2_RISCV_TOOLCHAIN_ARCHIVE" && "$RISCV_TOOLCHAIN_SHA256" == "$PHASE2_RISCV_TOOLCHAIN_SHA256" ]] || die 'toolchain dependency differs from Phase 2'
[[ "$IREE_COMPILER_VERSION" == unknown && "$IREE_LLVM_VERSION" == 24.0.0git ]] || die 'compiler identity mismatch'

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

manifest_keys=(
  SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT IREE_COMPILER_VERSION
  IREE_LLVM_VERSION IREE_SOURCE_REVISION IREE_HOST_ARCHIVE IREE_HOST_SHA256
  RISCV_TOOLCHAIN_ARCHIVE RISCV_TOOLCHAIN_SHA256 TARGET_TRIPLE TARGET_ABI
  TARGET_CPU_FEATURES OPT_LEVEL HAL_TARGET_DEVICE HAL_TARGET_BACKEND
  EXECUTABLE_FORMAT UKERNELS INPUT_MLIR_SHA256 VMFB_SHA256
  DUMPS_SHA256_FILE_SHA256
)
inspection_keys=(
  SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT
  SCALAR_COMPILE_MANIFEST_SHA256 RVV_COMPILE_MANIFEST_SHA256
  SCALAR_VMFB_SHA256 RVV_VMFB_SHA256 SCALAR_PAYLOAD_PATH SCALAR_PAYLOAD_SHA256
  RVV_PAYLOAD_PATH RVV_PAYLOAD_SHA256 READELF_PATH READELF_VERSION
  OBJDUMP_PATH OBJDUMP_VERSION SCALAR_CONFIG_COUNT SCALAR_DATA_COUNT
  SCALAR_TOTAL_COUNT RVV_CONFIG_COUNT RVV_DATA_COUNT RVV_TOTAL_COUNT
  ATTRIBUTE_STATUS INSPECTION_RESULT
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
READELF="$TOOLCHAIN_DIR/$RISCV_READELF_RELATIVE"
OBJDUMP="$TOOLCHAIN_DIR/$RISCV_OBJDUMP_RELATIVE"
[[ -x "$READELF" && -x "$OBJDUMP" ]] || die 'target-prefixed ELF tools are missing'
CURRENT_COMMIT="$(git rev-parse HEAD)"
if [[ "$REVIEW" == true ]]; then ROOT=build/iree/rvv-validation/review; BINDING=REVIEW_WORKTREE; else
  ROOT=build/iree/rvv-validation; BINDING=PUSHED_COMMIT
  [[ -z "$(git status --porcelain)" ]] || die 'final mode requires a clean working tree'
  git fetch origin --prune --quiet
  git branch --remotes --contains "$CURRENT_COMMIT" | grep -q 'origin/' || die "commit $CURRENT_COMMIT is not pushed"
fi
INPUT_SHA256="$(sha256_of "$SOURCE")"

validate_variant() {
  local name="$1" expected_features="$2" expected_level="$3" expected_input_hash="$4"
  local directory="$ROOT/$name"
  local manifest="$directory/compile.manifest"
  local vmfb
  if [[ "$name" == scalar ]]; then vmfb="$directory/tensor_add_scalar.vmfb"; else vmfb="$directory/tensor_add_rvv.vmfb"; fi
  [[ -f "$manifest" && -s "$vmfb" && -f "$vmfb.sha256" && -f "$directory/dumps.sha256" ]] || die "missing $name compilation evidence"
  declare -gA "${name^^}_VALUES=()"
  local -n values="${name^^}_VALUES"
  parse_manifest "$manifest" values "${manifest_keys[@]}"
  [[ "${values[SCHEMA_VERSION]}" == "$SCHEMA_VERSION" && "${values[ARTIFACT_BINDING]}" == "$BINDING" && "${values[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" ]] || die "$name binding mismatch"
  [[ "${values[IREE_COMPILER_VERSION]}" == "$IREE_COMPILER_VERSION" && "${values[IREE_LLVM_VERSION]}" == "$IREE_LLVM_VERSION" && "${values[IREE_SOURCE_REVISION]}" == "$IREE_SOURCE_REVISION" ]] || die "$name compiler identity mismatch"
  [[ "${values[IREE_HOST_ARCHIVE]}" == "$IREE_HOST_ARCHIVE" && "${values[IREE_HOST_SHA256]}" == "$IREE_HOST_SHA256" && "${values[RISCV_TOOLCHAIN_ARCHIVE]}" == "$RISCV_TOOLCHAIN_ARCHIVE" && "${values[RISCV_TOOLCHAIN_SHA256]}" == "$RISCV_TOOLCHAIN_SHA256" ]] || die "$name dependency identity mismatch"
  [[ "${values[TARGET_TRIPLE]}" == "$TARGET_TRIPLE" && "${values[TARGET_ABI]}" == "$TARGET_ABI" && "${values[TARGET_CPU_FEATURES]}" == "$expected_features" && "${values[OPT_LEVEL]}" == "$expected_level" ]] || die "$name target mismatch"
  [[ "${values[HAL_TARGET_DEVICE]}" == local && "${values[HAL_TARGET_BACKEND]}" == llvm-cpu && "${values[EXECUTABLE_FORMAT]}" == embedded-elf && "${values[UKERNELS]}" == disabled ]] || die "$name lowering contract mismatch"
  [[ "${values[INPUT_MLIR_SHA256]}" == "$expected_input_hash" && "${values[VMFB_SHA256]}" == "$(sha256_of "$vmfb")" && "${values[DUMPS_SHA256_FILE_SHA256]}" == "$(sha256_of "$directory/dumps.sha256")" ]] || die "$name hash mismatch"
  local sidecar_line
  IFS= read -r sidecar_line < "$vmfb.sha256"
  [[ "$sidecar_line" == "${values[VMFB_SHA256]}  $(basename "$vmfb")" && "$(wc -l < "$vmfb.sha256")" -eq 1 ]] || die "$name sidecar mismatch"
  (cd "$directory/dumps" && sha256sum --check ../dumps.sha256 >/dev/null) || die "$name dump checksum failure"
}

inventory_dumps() {
  local directory="$1" output="$2" file
  : > "$output"
  shopt -s nullglob
  for file in "$directory"/*; do
    [[ -f "$file" ]] && printf '%s  %s\n' "$(sha256_of "$file")" "$file" >> "$output"
  done
  shopt -u nullglob
  sort -o "$output" "$output"
}

select_payload() {
  local directory="$1" destination_name="$2"
  local -a payloads=()
  local file
  shopt -s nullglob
  for file in "$directory"/*.so; do [[ -s "$file" ]] && payloads+=("$file"); done
  shopt -u nullglob
  [[ "${#payloads[@]}" -eq 1 ]] || die "expected exactly one nonempty .so payload in $directory; found ${#payloads[@]}"
  printf -v "$destination_name" '%s' "${payloads[0]}"
}

scan_disassembly() {
  local disassembly="$1" output="$2" prefix="$3"
  local config data total
  config="$(awk '$1 ~ /^[0-9a-f]+:$/ && $2 ~ /^[0-9a-f]+$/ && ($3=="vsetvli" || $3=="vsetivli" || $3=="vsetvl") {count++} END {print count+0}' "$disassembly")"
  data="$(awk '$1 ~ /^[0-9a-f]+:$/ && $2 ~ /^[0-9a-f]+$/ && $3 ~ /^v/ && $3!="vsetvli" && $3!="vsetivli" && $3!="vsetvl" {count++} END {print count+0}' "$disassembly")"
  total=$((config + data))
  printf 'CONFIG_COUNT=%d\nDATA_COUNT=%d\nTOTAL_COUNT=%d\n' "$config" "$data" "$total" > "$output"
  awk '$1 ~ /^[0-9a-f]+:$/ && $2 ~ /^[0-9a-f]+$/ && (($3=="vsetvli" || $3=="vsetivli" || $3=="vsetvl") || ($3 ~ /^v/ && $3!="vsetvli" && $3!="vsetivli" && $3!="vsetvl")) {print}' "$disassembly" >> "$output"
  printf -v "${prefix}_CONFIG_COUNT" '%d' "$config"
  printf -v "${prefix}_DATA_COUNT" '%d' "$data"
  printf -v "${prefix}_TOTAL_COUNT" '%d' "$total"
}

arch_attribute() {
  local attributes="$1" destination_name="$2"
  local line value=''
  while IFS= read -r line; do
    if [[ "$line" == *Tag_RISCV_arch:* ]]; then value="${line#*\"}"; value="${value%%\"*}"; break; fi
  done < "$attributes"
  printf -v "$destination_name" '%s' "$value"
}

has_vector_attribute_token() {
  local value="$1" token
  value="${value//_/ }"
  for token in $value; do
    [[ "$token" =~ ^v[0-9] || "$token" == zve* || "$token" == zvl* ]] && return 0
  done
  return 1
}

attribute_has() {
  local value="$1" wanted="$2" token
  value="${value//_/ }"
  for token in $value; do [[ "$token" == "$wanted"* ]] && return 0; done
  return 1
}

first_version_line() {
  local executable="$1" destination_name="$2" line
  IFS= read -r line < <("$executable" --version)
  printf -v "$destination_name" '%s' "$line"
}

write_no_rvv_diagnostics() {
  local rvv_dump="$ROOT/rvv/dumps" propagation="$ROOT/inspection/target-propagation.txt" stages="$ROOT/inspection/optimization-stage-comparison.txt"
  local -a config_mlir=() codegen=() linked=() optimized=() assemblies=()
  shopt -s nullglob
  config_mlir=("$rvv_dump"/*configured*.mlir)
  codegen=("$rvv_dump"/*.codegen.ll)
  linked=("$rvv_dump"/*.linked.ll)
  optimized=("$rvv_dump"/*.optimized.ll)
  assemblies=("$rvv_dump"/*.s)
  shopt -u nullglob
  [[ "${#config_mlir[@]}" -gt 0 && "${#codegen[@]}" -gt 0 && "${#linked[@]}" -gt 0 && "${#optimized[@]}" -gt 0 ]] || die 'cannot locate propagation diagnostic stages'
  : > "$propagation"
  local token file stage missing=0
  IFS=',' read -r -a feature_tokens <<< "$RVV_CPU_FEATURES"
  for stage in configuration codegen linked optimized; do
    case "$stage" in
      configuration) stage_files=("${config_mlir[@]}") ;;
      codegen) stage_files=("${codegen[@]}") ;;
      linked) stage_files=("${linked[@]}") ;;
      optimized) stage_files=("${optimized[@]}") ;;
    esac
    for token in "${feature_tokens[@]}"; do
      local found=false
      for file in "${stage_files[@]}"; do grep -F -- "$token" "$file" >/dev/null && found=true && break; done
      printf '%s_%s=%s\n' "${stage^^}" "${token#+}" "$found" >> "$propagation"
      [[ "$found" == true ]] || missing=$((missing + 1))
    done
  done
  printf 'MISSING_TOKEN_COUNT=%d\n' "$missing" >> "$propagation"
  : > "$stages"
  for stage in codegen linked optimized; do
    case "$stage" in codegen) stage_files=("${codegen[@]}");; linked) stage_files=("${linked[@]}");; optimized) stage_files=("${optimized[@]}");; esac
    fixed="$(grep -Ehc '<[0-9]+ x ' "${stage_files[@]}" | awk '{s+=$1} END {print s+0}')"
    scalable="$(grep -Ehc '<vscale x [0-9]+ x ' "${stage_files[@]}" | awk '{s+=$1} END {print s+0}')"
    intrinsics="$(grep -Ehc 'llvm\.riscv\.' "${stage_files[@]}" | awk '{s+=$1} END {print s+0}')"
    printf '%s_FIXED_VECTOR_LINES=%s\n%s_SCALABLE_VECTOR_LINES=%s\n%s_RISCV_INTRINSIC_LINES=%s\n' "${stage^^}" "$fixed" "${stage^^}" "$scalable" "${stage^^}" "$intrinsics" >> "$stages"
  done
  assembly_rvv=0
  for file in "${assemblies[@]}"; do
    count="$(grep -Ec '^[[:space:]]*v(set(vli|ivli|vl)|[[:alnum:]_.]+)[[:space:]]' "$file" || true)"
    assembly_rvv=$((assembly_rvv + count))
  done
  printf 'ASSEMBLY_RVV_LINES=%d\nFINAL_PAYLOAD_RVV_LINES=%d\n' "$assembly_rvv" "$RVV_TOTAL_COUNT" >> "$stages"
}

inspect_diagnostic() {
  local primary="$ROOT/inspection/inspection.manifest"
  [[ -f "$primary" ]] || die 'diagnostic inspection requires primary inspection evidence'
  declare -A primary_values=()
  parse_manifest "$primary" primary_values "${inspection_keys[@]}"
  [[ "${primary_values[INSPECTION_RESULT]}" == RESULT_B_NO_RVV ]] || die 'diagnostics require RESULT_B_NO_RVV'
  local diag_root="$ROOT/diagnostics/$DIAGNOSTIC"
  local rvv_dir="$diag_root/rvv"
  [[ -f "$diag_root/diagnostic.context" ]] || die "missing diagnostic context: $diag_root"
  local expected_level=O3 expected_input_hash="$INPUT_SHA256"
  if [[ "$DIAGNOSTIC" == length-4096 ]]; then expected_level=O2; expected_input_hash="$(sha256_of "$diag_root/tensor_add_4096.mlir")"; fi
  local saved_root="$ROOT"
  ROOT="$diag_root"
  validate_variant rvv "$RVV_CPU_FEATURES" "$expected_level" "$expected_input_hash"
  ROOT="$saved_root"
  local payload
  select_payload "$rvv_dir/dumps" payload
  "$OBJDUMP" -d "$payload" > "$diag_root/rvv-disassembly.txt"
  scan_disassembly "$diag_root/rvv-disassembly.txt" "$diag_root/rvv-rvv-scan.txt" DIAGNOSTIC
  printf 'DIAGNOSTIC_KIND=%s\nPRIMARY_RESULT=RESULT_B_NO_RVV\nPAYLOAD_PATH=%s\nPAYLOAD_SHA256=%s\nCONFIG_COUNT=%s\nDATA_COUNT=%s\nTOTAL_COUNT=%s\n' "$DIAGNOSTIC" "$payload" "$(sha256_of "$payload")" "$DIAGNOSTIC_CONFIG_COUNT" "$DIAGNOSTIC_DATA_COUNT" "$DIAGNOSTIC_TOTAL_COUNT" > "$diag_root/inspection-summary.txt"
  printf 'SCHEMA_VERSION=%s\nDIAGNOSTIC_KIND=%s\nPRIMARY_RESULT=RESULT_B_NO_RVV\nPAYLOAD_SHA256=%s\nCONFIG_COUNT=%s\nDATA_COUNT=%s\nTOTAL_COUNT=%s\n' "$SCHEMA_VERSION" "$DIAGNOSTIC" "$(sha256_of "$payload")" "$DIAGNOSTIC_CONFIG_COUNT" "$DIAGNOSTIC_DATA_COUNT" "$DIAGNOSTIC_TOTAL_COUNT" > "$diag_root/inspection.manifest"
  printf 'Diagnostic inspection complete: %s\n' "$diag_root"
}

if [[ -n "$DIAGNOSTIC" ]]; then inspect_diagnostic; exit 0; fi

validate_variant scalar "$SCALAR_CPU_FEATURES" "$OPT_LEVEL" "$INPUT_SHA256"
validate_variant rvv "$RVV_CPU_FEATURES" "$OPT_LEVEL" "$INPUT_SHA256"
for key in SCHEMA_VERSION ARTIFACT_BINDING REPOSITORY_COMMIT IREE_COMPILER_VERSION IREE_LLVM_VERSION IREE_SOURCE_REVISION IREE_HOST_ARCHIVE IREE_HOST_SHA256 RISCV_TOOLCHAIN_ARCHIVE RISCV_TOOLCHAIN_SHA256 TARGET_TRIPLE TARGET_ABI OPT_LEVEL HAL_TARGET_DEVICE HAL_TARGET_BACKEND EXECUTABLE_FORMAT UKERNELS INPUT_MLIR_SHA256; do
  [[ "${SCALAR_VALUES[$key]}" == "${RVV_VALUES[$key]}" ]] || die "variant manifest invariant differs: $key"
done

INSPECTION="$ROOT/inspection"
mkdir -p "$INSPECTION"
inventory_dumps "$ROOT/scalar/dumps" "$INSPECTION/scalar-dump-inventory.txt"
inventory_dumps "$ROOT/rvv/dumps" "$INSPECTION/rvv-dump-inventory.txt"
select_payload "$ROOT/scalar/dumps" SCALAR_PAYLOAD
select_payload "$ROOT/rvv/dumps" RVV_PAYLOAD
SCALAR_PAYLOAD_SHA256="$(sha256_of "$SCALAR_PAYLOAD")"
RVV_PAYLOAD_SHA256="$(sha256_of "$RVV_PAYLOAD")"
for variant in scalar rvv; do
  if [[ "$variant" == scalar ]]; then payload="$SCALAR_PAYLOAD"; else payload="$RVV_PAYLOAD"; fi
  "$READELF" -h "$payload" > "$INSPECTION/$variant-elf-header.txt"
  "$READELF" -A "$payload" > "$INSPECTION/$variant-attributes.txt"
  "$READELF" -sW "$payload" > "$INSPECTION/$variant-symbols.txt"
  "$OBJDUMP" -d "$payload" > "$INSPECTION/$variant-disassembly.txt"
  grep -E 'Class:[[:space:]]+ELF64' "$INSPECTION/$variant-elf-header.txt" >/dev/null || die "$variant payload is not ELF64"
  grep -E 'Machine:[[:space:]]+RISC-V' "$INSPECTION/$variant-elf-header.txt" >/dev/null || die "$variant payload is not RISC-V"
  grep -F 'double-float ABI' "$INSPECTION/$variant-elf-header.txt" >/dev/null || die "$variant payload does not use double-float ABI"
done
scan_disassembly "$INSPECTION/scalar-disassembly.txt" "$INSPECTION/scalar-rvv-scan.txt" SCALAR
scan_disassembly "$INSPECTION/rvv-disassembly.txt" "$INSPECTION/rvv-rvv-scan.txt" RVV
arch_attribute "$INSPECTION/scalar-attributes.txt" SCALAR_ARCH
arch_attribute "$INSPECTION/rvv-attributes.txt" RVV_ARCH

RESULT=PASS
ATTRIBUTE_STATUS=NOT_PRESENT
if [[ "$SCALAR_CONFIG_COUNT" -ne 0 || "$SCALAR_DATA_COUNT" -ne 0 ]] || has_vector_attribute_token "$SCALAR_ARCH"; then RESULT=SCALAR_CONTAMINATION; fi
if [[ -n "$RVV_ARCH" ]]; then
  ATTRIBUTE_STATUS=PRESENT
  if ! attribute_has "$RVV_ARCH" v || ! attribute_has "$RVV_ARCH" zvl256b; then RESULT=RVV_ATTRIBUTE_MISMATCH; fi
fi
if [[ "$RESULT" == PASS && ( "$RVV_CONFIG_COUNT" -eq 0 || "$RVV_DATA_COUNT" -eq 0 ) ]]; then RESULT=RESULT_B_NO_RVV; fi

first_version_line "$READELF" READELF_VERSION
first_version_line "$OBJDUMP" OBJDUMP_VERSION
config_mnemonics="$(awk '$1 ~ /^[0-9a-f]+:$/ && ($3=="vsetvli" || $3=="vsetivli" || $3=="vsetvl") {print $3}' "$INSPECTION/rvv-disassembly.txt" | sort -u | paste -sd, -)"
data_mnemonics="$(awk '$1 ~ /^[0-9a-f]+:$/ && $3 ~ /^v/ && $3!="vsetvli" && $3!="vsetivli" && $3!="vsetvl" {print $3}' "$INSPECTION/rvv-disassembly.txt" | sort -u | awk 'NR<=5' | paste -sd, -)"
printf '%s\n' \
  "SCALAR_PAYLOAD_PATH=$SCALAR_PAYLOAD" "SCALAR_PAYLOAD_SHA256=$SCALAR_PAYLOAD_SHA256" \
  "RVV_PAYLOAD_PATH=$RVV_PAYLOAD" "RVV_PAYLOAD_SHA256=$RVV_PAYLOAD_SHA256" \
  "READELF_PATH=$READELF" "READELF_VERSION=$READELF_VERSION" \
  "OBJDUMP_PATH=$OBJDUMP" "OBJDUMP_VERSION=$OBJDUMP_VERSION" \
  "SCALAR_CONFIG_COUNT=$SCALAR_CONFIG_COUNT" "SCALAR_DATA_COUNT=$SCALAR_DATA_COUNT" "SCALAR_TOTAL_COUNT=$SCALAR_TOTAL_COUNT" \
  "RVV_CONFIG_COUNT=$RVV_CONFIG_COUNT" "RVV_DATA_COUNT=$RVV_DATA_COUNT" "RVV_TOTAL_COUNT=$RVV_TOTAL_COUNT" \
  "RVV_CONFIG_MNEMONICS=$config_mnemonics" "RVV_REPRESENTATIVE_DATA_MNEMONICS=$data_mnemonics" \
  "ATTRIBUTE_STATUS=$ATTRIBUTE_STATUS" "INSPECTION_RESULT=$RESULT" > "$INSPECTION/inspection-summary.txt"

SCALAR_MANIFEST_SHA256="$(sha256_of "$ROOT/scalar/compile.manifest")"
RVV_MANIFEST_SHA256="$(sha256_of "$ROOT/rvv/compile.manifest")"
printf '%s\n' \
  "SCHEMA_VERSION=$SCHEMA_VERSION" "ARTIFACT_BINDING=$BINDING" "REPOSITORY_COMMIT=$CURRENT_COMMIT" \
  "SCALAR_COMPILE_MANIFEST_SHA256=$SCALAR_MANIFEST_SHA256" "RVV_COMPILE_MANIFEST_SHA256=$RVV_MANIFEST_SHA256" \
  "SCALAR_VMFB_SHA256=${SCALAR_VALUES[VMFB_SHA256]}" "RVV_VMFB_SHA256=${RVV_VALUES[VMFB_SHA256]}" \
  "SCALAR_PAYLOAD_PATH=$SCALAR_PAYLOAD" "SCALAR_PAYLOAD_SHA256=$SCALAR_PAYLOAD_SHA256" \
  "RVV_PAYLOAD_PATH=$RVV_PAYLOAD" "RVV_PAYLOAD_SHA256=$RVV_PAYLOAD_SHA256" \
  "READELF_PATH=$READELF" "READELF_VERSION=$READELF_VERSION" "OBJDUMP_PATH=$OBJDUMP" "OBJDUMP_VERSION=$OBJDUMP_VERSION" \
  "SCALAR_CONFIG_COUNT=$SCALAR_CONFIG_COUNT" "SCALAR_DATA_COUNT=$SCALAR_DATA_COUNT" "SCALAR_TOTAL_COUNT=$SCALAR_TOTAL_COUNT" \
  "RVV_CONFIG_COUNT=$RVV_CONFIG_COUNT" "RVV_DATA_COUNT=$RVV_DATA_COUNT" "RVV_TOTAL_COUNT=$RVV_TOTAL_COUNT" \
  "ATTRIBUTE_STATUS=$ATTRIBUTE_STATUS" "INSPECTION_RESULT=$RESULT" > "$INSPECTION/inspection.manifest"
declare -A inspection_values=()
parse_manifest "$INSPECTION/inspection.manifest" inspection_values "${inspection_keys[@]}"
[[ "${inspection_values[INSPECTION_RESULT]}" == "$RESULT" && "${inspection_values[SCALAR_PAYLOAD_SHA256]}" == "$SCALAR_PAYLOAD_SHA256" && "${inspection_values[RVV_PAYLOAD_SHA256]}" == "$RVV_PAYLOAD_SHA256" ]] || die 'inspection manifest validation failed'

if [[ "$RESULT" == RESULT_B_NO_RVV ]]; then write_no_rvv_diagnostics; fi
printf 'Inspection result: %s\n' "$RESULT"
[[ "$RESULT" == PASS || "$RESULT" == RESULT_B_NO_RVV ]] || exit 1
