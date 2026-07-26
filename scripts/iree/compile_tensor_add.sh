#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    printf 'Usage: compile_tensor_add.sh\n' >&2
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "$#" -ne 0 ]]; then
    usage
    exit 2
fi

for command_name in git mkdir rm sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this command from inside the Git repository"
cd "$REPO_ROOT"

CONFIG_FILE="scripts/iree/iree.env"
SOURCE_FILE="src/iree/tensor_add.mlir"
HOST_DIR="build/iree/deps/iree-host"
HOST_MARKER="$HOST_DIR/.iree-dependency"
IREE_COMPILE="$HOST_DIR/bin/iree-compile"
IREE_RUN_MODULE="$HOST_DIR/bin/iree-run-module"
HOST_OUTPUT_DIR="build/iree/host"
SCALAR_OUTPUT_DIR="build/iree/scalar"
HOST_VMFB="$HOST_OUTPUT_DIR/tensor_add.vmfb"
SCALAR_VMFB="$SCALAR_OUTPUT_DIR/tensor_add.vmfb"
SCALAR_SIDECAR="$SCALAR_VMFB.sha256"
MANIFEST_FILE="build/iree/compile-manifest.txt"

[[ -f "$CONFIG_FILE" ]] || die "missing configuration: $CONFIG_FILE"
# shellcheck source=iree.env
. "$CONFIG_FILE"

required_config_keys=(
    IREE_REVISION
    IREE_HOST_ARCHIVE
    IREE_HOST_SHA256
    IREE_TARGET_TRIPLE
    IREE_TARGET_ABI
    IREE_TARGET_CPU_FEATURES
    IREE_OPT_LEVEL
)
for config_key in "${required_config_keys[@]}"; do
    [[ -n "${!config_key:-}" ]] ||
        die "missing or empty configuration value: $config_key"
done

[[ "$IREE_TARGET_TRIPLE" == riscv64 ]] ||
    die "IREE_TARGET_TRIPLE must be riscv64, got: $IREE_TARGET_TRIPLE"
[[ "$IREE_TARGET_ABI" == lp64d ]] ||
    die "IREE_TARGET_ABI must be lp64d, got: $IREE_TARGET_ABI"
[[ "$IREE_TARGET_CPU_FEATURES" == '+m,+a,+f,+d,+c' ]] ||
    die "IREE_TARGET_CPU_FEATURES must be scalar +m,+a,+f,+d,+c, got: $IREE_TARGET_CPU_FEATURES"
[[ "$IREE_OPT_LEVEL" == O2 ]] ||
    die "IREE_OPT_LEVEL must be O2, got: $IREE_OPT_LEVEL"

[[ -f "$SOURCE_FILE" ]] || die "missing tensor source: $SOURCE_FILE"
[[ -f "$HOST_MARKER" ]] ||
    die "missing prepared host marker: $HOST_MARKER; run ./scripts/iree/prepare_iree.sh first"
[[ -x "$IREE_COMPILE" ]] ||
    die "missing prepared executable: $IREE_COMPILE; run ./scripts/iree/prepare_iree.sh first"
[[ -x "$IREE_RUN_MODULE" ]] ||
    die "missing prepared executable: $IREE_RUN_MODULE; run ./scripts/iree/prepare_iree.sh first"

mapfile -t host_marker_lines < "$HOST_MARKER"
if [[ "${#host_marker_lines[@]}" -ne 2 \
        || "${host_marker_lines[0]}" != "archive=$IREE_HOST_ARCHIVE" \
        || "${host_marker_lines[1]}" != "sha256=$IREE_HOST_SHA256" ]]; then
    die "$HOST_MARKER does not exactly match the configured host archive and SHA-256"
fi

mkdir -p "$HOST_OUTPUT_DIR" "$SCALAR_OUTPUT_DIR"
rm -f "$HOST_VMFB" "$SCALAR_VMFB" "$SCALAR_SIDECAR" "$MANIFEST_FILE"

HOST_COMPILE_COMMAND=(
    "$IREE_COMPILE"
    "$SOURCE_FILE"
    --iree-hal-target-device=local
    --iree-hal-local-target-device-backends=llvm-cpu
    --iree-llvmcpu-target-cpu=host
    "--iree-opt-level=$IREE_OPT_LEVEL"
    -o
    "$HOST_VMFB"
)
HOST_RUN_COMMAND=(
    "$IREE_RUN_MODULE"
    --device=local-task
    "--module=$HOST_VMFB"
    --function=add
    '--input=4xf32=1 2 3 4'
    '--input=4xf32=10 20 30 40'
    '--expected_output=4xf32=11 22 33 44'
)
SCALAR_COMPILE_COMMAND=(
    "$IREE_COMPILE"
    "$SOURCE_FILE"
    --iree-hal-target-device=local
    --iree-hal-local-target-device-backends=llvm-cpu
    "--iree-llvmcpu-target-triple=$IREE_TARGET_TRIPLE"
    "--iree-llvmcpu-target-abi=$IREE_TARGET_ABI"
    "--iree-llvmcpu-target-cpu-features=$IREE_TARGET_CPU_FEATURES"
    "--iree-opt-level=$IREE_OPT_LEVEL"
    -o
    "$SCALAR_VMFB"
)

printf 'Repository:       %s\n' "$REPO_ROOT"
printf 'IREE revision:    %s\n' "$IREE_REVISION"
printf 'Host compiler:    %s\n' "$IREE_COMPILE"
printf 'Tensor source:    %s\n' "$SOURCE_FILE"
printf 'Target triple:    %s\n' "$IREE_TARGET_TRIPLE"
printf 'Target ABI:       %s\n' "$IREE_TARGET_ABI"
printf 'Target features:  %s\n' "$IREE_TARGET_CPU_FEATURES"
printf 'Optimization:     %s\n' "$IREE_OPT_LEVEL"
printf '\nCompiling host correctness artifact...\n'
"${HOST_COMPILE_COMMAND[@]}"
[[ -s "$HOST_VMFB" ]] || die "host compiler produced no artifact: $HOST_VMFB"

printf 'Running host numerical correctness check...\n'
"${HOST_RUN_COMMAND[@]}"

printf '\nCompiling scalar riscv64 artifact...\n'
"${SCALAR_COMPILE_COMMAND[@]}"
[[ -s "$SCALAR_VMFB" ]] || die "scalar compiler produced no artifact: $SCALAR_VMFB"

sha256_of()
{
    local digest ignored
    read -r digest ignored < <(sha256sum "$1")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
        die "invalid SHA-256 output for $1"
    printf '%s' "$digest"
}

serialize_command()
{
    local serialized
    printf -v serialized '%q ' "$@"
    [[ "$serialized" != *$'\n'* ]] || die "serialized command contains a newline"
    printf '%s' "$serialized"
}

REPOSITORY_COMMIT="$(git rev-parse HEAD)"
CONFIG_SHA256="$(sha256_of "$CONFIG_FILE")"
SOURCE_SHA256="$(sha256_of "$SOURCE_FILE")"
HOST_VMFB_SHA256="$(sha256_of "$HOST_VMFB")"
SCALAR_VMFB_SHA256="$(sha256_of "$SCALAR_VMFB")"
HOST_COMMAND="$(serialize_command "${HOST_COMPILE_COMMAND[@]}")"
SCALAR_COMMAND="$(serialize_command "${SCALAR_COMPILE_COMMAND[@]}")"

printf '%s  tensor_add.vmfb\n' "$SCALAR_VMFB_SHA256" > "$SCALAR_SIDECAR"

printf '%s\n' \
    "REPOSITORY_COMMIT=$REPOSITORY_COMMIT" \
    "IREE_REVISION=$IREE_REVISION" \
    "CONFIG_SHA256=$CONFIG_SHA256" \
    "SOURCE_SHA256=$SOURCE_SHA256" \
    "HOST_COMMAND=$HOST_COMMAND" \
    "SCALAR_COMMAND=$SCALAR_COMMAND" \
    "HOST_VMFB_SHA256=$HOST_VMFB_SHA256" \
    "SCALAR_VMFB_SHA256=$SCALAR_VMFB_SHA256" \
    > "$MANIFEST_FILE"

required_manifest_keys=(
    REPOSITORY_COMMIT
    IREE_REVISION
    CONFIG_SHA256
    SOURCE_SHA256
    HOST_COMMAND
    SCALAR_COMMAND
    HOST_VMFB_SHA256
    SCALAR_VMFB_SHA256
)
declare -A expected_manifest_values=(
    [REPOSITORY_COMMIT]="$REPOSITORY_COMMIT"
    [IREE_REVISION]="$IREE_REVISION"
    [CONFIG_SHA256]="$CONFIG_SHA256"
    [SOURCE_SHA256]="$SOURCE_SHA256"
    [HOST_COMMAND]="$HOST_COMMAND"
    [SCALAR_COMMAND]="$SCALAR_COMMAND"
    [HOST_VMFB_SHA256]="$HOST_VMFB_SHA256"
    [SCALAR_VMFB_SHA256]="$SCALAR_VMFB_SHA256"
)
declare -A parsed_manifest_values=()

while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
    [[ "$manifest_line" == *=* ]] ||
        die "malformed manifest line without '=': $manifest_line"
    manifest_key="${manifest_line%%=*}"
    manifest_value="${manifest_line#*=}"
    [[ "$manifest_key" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
        die "malformed manifest key: $manifest_key"
    [[ -v "expected_manifest_values[$manifest_key]" ]] ||
        die "unknown manifest key: $manifest_key"
    [[ ! -v "parsed_manifest_values[$manifest_key]" ]] ||
        die "duplicate manifest key: $manifest_key"
    parsed_manifest_values["$manifest_key"]="$manifest_value"
done < "$MANIFEST_FILE"

for manifest_key in "${required_manifest_keys[@]}"; do
    [[ -v "parsed_manifest_values[$manifest_key]" ]] ||
        die "missing manifest key: $manifest_key"
    [[ "${parsed_manifest_values[$manifest_key]}" == \
        "${expected_manifest_values[$manifest_key]}" ]] ||
        die "manifest value mismatch for key: $manifest_key"
done
[[ "${#parsed_manifest_values[@]}" -eq "${#required_manifest_keys[@]}" ]] ||
    die "manifest key count mismatch"

mapfile -t sidecar_lines < "$SCALAR_SIDECAR"
[[ "${#sidecar_lines[@]}" -eq 1 \
        && "${sidecar_lines[0]}" == "$SCALAR_VMFB_SHA256  tensor_add.vmfb" ]] ||
    die "invalid scalar SHA-256 sidecar: $SCALAR_SIDECAR"

printf '\nHost tensor-add check passed.\n'
printf 'Host VMFB:       %s\n' "$HOST_VMFB"
printf 'Scalar VMFB:     %s\n' "$SCALAR_VMFB"
printf 'Scalar sidecar:  %s\n' "$SCALAR_SIDECAR"
printf 'Compile manifest: %s\n' "$MANIFEST_FILE"
