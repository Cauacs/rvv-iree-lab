#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    printf 'Usage: build_riscv_runtime.sh\n' >&2
    printf 'Environment:\n' >&2
    printf '  RUNTIME_LINKAGE=dynamic|static  (default: dynamic)\n' >&2
    printf '  JOBS=<positive integer>         (default: 2)\n' >&2
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

for command_name in git cmake ninja file du grep mkdir rm sha256sum python3; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this command from inside the Git repository"
cd "$REPO_ROOT"

CONFIG_FILE="phase2/config/iree.env"
TENSOR_SOURCE="phase2/mlir/tensor_add.mlir"
DEPS_DIR="build/phase2/deps"
HOST_DIR="$DEPS_DIR/iree-host"
TOOLCHAIN_DIR="$DEPS_DIR/riscv-toolchain"
SOURCE_DIR="$DEPS_DIR/iree-src"
HOST_MARKER="$HOST_DIR/.phase2-dependency"
TOOLCHAIN_MARKER="$TOOLCHAIN_DIR/.phase2-dependency"
IREE_COMPILE="$HOST_DIR/bin/iree-compile"
IREE_RUN_MODULE_HOST="$HOST_DIR/bin/iree-run-module"
IREE_DUMP_MODULE="$HOST_DIR/bin/iree-dump-module"
RV_CLANG="$TOOLCHAIN_DIR/bin/clang"
RV_CLANGXX="$TOOLCHAIN_DIR/bin/clang++"
RV_READELF="$TOOLCHAIN_DIR/bin/riscv64-unknown-linux-gnu-readelf"
RV_SYSROOT="$TOOLCHAIN_DIR/sysroot"
TOOLCHAIN_FILE="$SOURCE_DIR/build_tools/cmake/linux_riscv64.cmake"
RUNTIME_SUBMODULES_FILE="$SOURCE_DIR/build_tools/scripts/git/runtime_submodules.txt"
SUBMODULE_CHECKER="$SOURCE_DIR/build_tools/scripts/git/check_submodule_init.py"
SCALAR_VMFB="build/phase2/scalar/tensor_add.vmfb"
SCALAR_SIDECAR="$SCALAR_VMFB.sha256"
COMPILE_MANIFEST="build/phase2/compile-manifest.txt"

[[ -f "$CONFIG_FILE" ]] || die "missing configuration: $CONFIG_FILE"
# shellcheck source=../config/iree.env
. "$CONFIG_FILE"

required_config_keys=(
    IREE_REVISION
    IREE_HOST_ARCHIVE
    IREE_HOST_SHA256
    RISCV_TOOLCHAIN_ARCHIVE
    RISCV_TOOLCHAIN_SHA256
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

RUNTIME_LINKAGE="${RUNTIME_LINKAGE:-dynamic}"
JOBS="${JOBS:-2}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer, got: $JOBS"

case "$RUNTIME_LINKAGE" in
    dynamic)
        BUILD_DIR="build/phase2/runtime-riscv64"
        RUNTIME_MANIFEST="build/phase2/runtime-manifest.txt"
        RESOURCE_REPORT="build/phase2/resource-usage.txt"
        ;;
    static)
        BUILD_DIR="build/phase2/runtime-riscv64-static"
        RUNTIME_MANIFEST="build/phase2/runtime-manifest-static.txt"
        RESOURCE_REPORT="build/phase2/resource-usage-static.txt"
        ;;
    *)
        die "RUNTIME_LINKAGE must be dynamic or static, got: $RUNTIME_LINKAGE"
        ;;
esac

RUNNER="$BUILD_DIR/tools/iree-run-module"
RUNNER_FILE_REPORT="$BUILD_DIR/iree-run-module.file.txt"
RUNNER_READELF_H="$BUILD_DIR/iree-run-module.readelf-h.txt"
RUNNER_READELF_A="$BUILD_DIR/iree-run-module.readelf-A.txt"
RUNNER_READELF_D="$BUILD_DIR/iree-run-module.readelf-d.txt"
RUNNER_SIDECAR="$BUILD_DIR/iree-run-module.sha256"

verify_dependency_marker()
{
    local marker="$1"
    local archive="$2"
    local digest="$3"
    local label="$4"

    [[ -f "$marker" ]] || die "missing $label dependency marker: $marker"
    local -a marker_lines
    mapfile -t marker_lines < "$marker"
    if [[ "${#marker_lines[@]}" -ne 2 \
            || "${marker_lines[0]}" != "archive=$archive" \
            || "${marker_lines[1]}" != "sha256=$digest" ]]; then
        die "$label dependency marker does not exactly match configured archive and SHA-256: $marker"
    fi
}

verify_dependency_marker "$HOST_MARKER" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" host
verify_dependency_marker "$TOOLCHAIN_MARKER" \
    "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256" RISC-V-toolchain

for executable in \
        "$IREE_COMPILE" "$IREE_RUN_MODULE_HOST" "$IREE_DUMP_MODULE" \
        "$RV_CLANG" "$RV_CLANGXX" "$RV_READELF"; do
    [[ -x "$executable" ]] || die "missing prepared executable: $executable"
done
[[ -d "$RV_SYSROOT" ]] || die "missing prepared sysroot: $RV_SYSROOT"
[[ -f "$TOOLCHAIN_FILE" ]] || die "missing IREE RISC-V toolchain file: $TOOLCHAIN_FILE"
[[ -f "$RUNTIME_SUBMODULES_FILE" ]] ||
    die "missing runtime submodule list: $RUNTIME_SUBMODULES_FILE"
[[ -f "$SUBMODULE_CHECKER" ]] || die "missing submodule checker: $SUBMODULE_CHECKER"

SOURCE_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null)" ||
    die "IREE source is not a valid Git checkout: $SOURCE_DIR"
[[ "$SOURCE_HEAD" == "$IREE_REVISION" ]] ||
    die "IREE source HEAD mismatch: expected $IREE_REVISION, got $SOURCE_HEAD"

while IFS= read -r submodule_path || [[ -n "$submodule_path" ]]; do
    submodule_path="${submodule_path%%#*}"
    submodule_path="${submodule_path//[$'\t\r ']/}"
    [[ -n "$submodule_path" ]] || continue
    submodule_status="$(git -C "$SOURCE_DIR" submodule status -- "$submodule_path")" ||
        die "cannot read runtime submodule status: $submodule_path"
    [[ "${submodule_status:0:1}" == ' ' ]] ||
        die "runtime submodule is not at its pinned initialized commit: $submodule_path ($submodule_status)"
done < "$RUNTIME_SUBMODULES_FILE"
(
    cd "$SOURCE_DIR"
    python3 build_tools/scripts/git/check_submodule_init.py --runtime_only
) || die "IREE runtime-only submodule validation failed"

[[ -f "$TENSOR_SOURCE" ]] || die "missing tensor source: $TENSOR_SOURCE"
[[ -s "$SCALAR_VMFB" ]] ||
    die "missing scalar VMFB: $SCALAR_VMFB; run ./phase2/scripts/compile_tensor_add.sh first"
[[ -f "$SCALAR_SIDECAR" ]] || die "missing scalar VMFB sidecar: $SCALAR_SIDECAR"
[[ -f "$COMPILE_MANIFEST" ]] || die "missing compile manifest: $COMPILE_MANIFEST"

sha256_of()
{
    local digest ignored
    read -r digest ignored < <(sha256sum "$1")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 output for $1"
    printf '%s' "$digest"
}

parse_manifest()
{
    local manifest="$1"
    local destination_name="$2"
    shift 2
    local -a allowed_keys=("$@")
    local -n destination="$destination_name"
    destination=()

    local line key value allowed_key known
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || die "malformed manifest line without '=' in $manifest: $line"
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "malformed manifest key in $manifest: $key"
        known=false
        for allowed_key in "${allowed_keys[@]}"; do
            if [[ "$key" == "$allowed_key" ]]; then
                known=true
                break
            fi
        done
        [[ "$known" == true ]] || die "unknown manifest key in $manifest: $key"
        [[ ! -v "destination[$key]" ]] || die "duplicate manifest key in $manifest: $key"
        destination["$key"]="$value"
    done < "$manifest"

    for allowed_key in "${allowed_keys[@]}"; do
        [[ -v "destination[$allowed_key]" ]] ||
            die "missing manifest key in $manifest: $allowed_key"
    done
    [[ "${#destination[@]}" -eq "${#allowed_keys[@]}" ]] ||
        die "manifest key count mismatch: $manifest"
}

compile_manifest_keys=(
    REPOSITORY_COMMIT IREE_REVISION CONFIG_SHA256 SOURCE_SHA256
    HOST_COMMAND SCALAR_COMMAND HOST_VMFB_SHA256 SCALAR_VMFB_SHA256
)
declare -A compile_values=()
parse_manifest "$COMPILE_MANIFEST" compile_values "${compile_manifest_keys[@]}"

REPOSITORY_COMMIT="$(git rev-parse HEAD)"
CONFIG_SHA256="$(sha256_of "$CONFIG_FILE")"
TENSOR_SOURCE_SHA256="$(sha256_of "$TENSOR_SOURCE")"
SCALAR_VMFB_SHA256="$(sha256_of "$SCALAR_VMFB")"
COMPILE_MANIFEST_SHA256="$(sha256_of "$COMPILE_MANIFEST")"

[[ "${compile_values[REPOSITORY_COMMIT]}" == "$REPOSITORY_COMMIT" ]] ||
    die "compile manifest repository commit is stale; rerun compile_tensor_add.sh"
[[ "${compile_values[IREE_REVISION]}" == "$IREE_REVISION" ]] ||
    die "compile manifest IREE revision mismatch; rerun compile_tensor_add.sh"
[[ "${compile_values[CONFIG_SHA256]}" == "$CONFIG_SHA256" ]] ||
    die "compile manifest configuration hash is stale; rerun compile_tensor_add.sh"
[[ "${compile_values[SOURCE_SHA256]}" == "$TENSOR_SOURCE_SHA256" ]] ||
    die "compile manifest source hash is stale; rerun compile_tensor_add.sh"
[[ -n "${compile_values[HOST_COMMAND]}" ]] || die "compile manifest HOST_COMMAND is empty"
[[ -n "${compile_values[SCALAR_COMMAND]}" ]] || die "compile manifest SCALAR_COMMAND is empty"
[[ "${compile_values[SCALAR_VMFB_SHA256]}" == "$SCALAR_VMFB_SHA256" ]] ||
    die "scalar VMFB digest does not match compile manifest"

mapfile -t scalar_sidecar_lines < "$SCALAR_SIDECAR"
[[ "${#scalar_sidecar_lines[@]}" -eq 1 \
        && "${scalar_sidecar_lines[0]}" == "$SCALAR_VMFB_SHA256  tensor_add.vmfb" ]] ||
    die "scalar VMFB sidecar is malformed or stale: $SCALAR_SIDECAR"

mkdir -p "$BUILD_DIR"
rm -f "$RUNTIME_MANIFEST" "$RESOURCE_REPORT" \
    "$RUNNER_FILE_REPORT" "$RUNNER_READELF_H" "$RUNNER_READELF_A" \
    "$RUNNER_READELF_D" "$RUNNER_SIDECAR"

CONFIGURE_COMMAND=(
    cmake
    -S "$SOURCE_DIR"
    -B "$BUILD_DIR"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_TOOLCHAIN_FILE=$REPO_ROOT/$TOOLCHAIN_FILE"
    "-DRISCV_TOOLCHAIN_ROOT=$REPO_ROOT/$TOOLCHAIN_DIR"
    "-DIREE_HOST_BIN_DIR=$REPO_ROOT/$HOST_DIR/bin"
    -DIREE_BUILD_COMPILER=OFF
    -DIREE_BUILD_TESTS=OFF
    -DIREE_BUILD_BENCHMARKS=OFF
    -DIREE_BUILD_SAMPLES=OFF
    -DIREE_BUILD_PYTHON_BINDINGS=OFF
    -DIREE_HAL_DRIVER_DEFAULTS=OFF
    -DIREE_HAL_DRIVER_LOCAL_TASK=ON
    -DIREE_HAL_EXECUTABLE_LOADER_DEFAULTS=OFF
    -DIREE_HAL_EXECUTABLE_PLUGIN_DEFAULTS=OFF
    -DIREE_UK_BUILD_RISCV_64_V=OFF
    -DIREE_UK_BUILD_RISCV_64_ZVFH=OFF
    -DIREE_UK_BUILD_RISCV_64_ZVFHMIN=OFF
    -DIREE_HAL_EXECUTABLE_LOADER_EMBEDDED_ELF=ON
)
if [[ "$RUNTIME_LINKAGE" == static ]]; then
    CONFIGURE_COMMAND+=("-DCMAKE_EXE_LINKER_FLAGS=-static")
fi
BUILD_COMMAND=(
    cmake --build "$BUILD_DIR"
    --target iree-run-module
    --parallel "$JOBS"
)

printf 'Repository:       %s\n' "$REPO_ROOT"
printf 'IREE revision:    %s\n' "$IREE_REVISION"
printf 'Runtime linkage:  %s\n' "$RUNTIME_LINKAGE"
printf 'Build directory:  %s\n' "$BUILD_DIR"
printf 'Jobs:             %s\n' "$JOBS"
printf 'Toolchain root:   %s\n' "$TOOLCHAIN_DIR"
printf 'Target ABI:       %s\n' "$IREE_TARGET_ABI"
printf 'Scalar VMFB:      %s\n' "$SCALAR_VMFB"

configure_start="$SECONDS"
"${CONFIGURE_COMMAND[@]}"
configure_elapsed="$((SECONDS - configure_start))"

[[ -f "$BUILD_DIR/build.ninja" ]] || die "CMake did not generate: $BUILD_DIR/build.ninja"
expected_march='-march=rv64i2p1ma2p1f2p2d2p2c2p0'
found_march=false
while IFS= read -r march_token; do
    found_march=true
    [[ "$march_token" == "$expected_march" ]] ||
        die "generated build contains a non-scalar -march: $march_token"
done < <(grep -oE -- '-march=[^[:space:]]+' "$BUILD_DIR/build.ninja")
[[ "$found_march" == true ]] ||
    die "generated build does not contain the pinned scalar RISC-V -march"

found_mabi=false
while IFS= read -r mabi_token; do
    found_mabi=true
    [[ "$mabi_token" == '-mabi=lp64d' ]] ||
        die "generated build contains an unexpected -mabi: $mabi_token"
done < <(grep -oE -- '-mabi=[^[:space:]]+' "$BUILD_DIR/build.ninja")
[[ "$found_mabi" == true ]] || die "generated build does not contain -mabi=lp64d"

build_start="$SECONDS"
"${BUILD_COMMAND[@]}"
build_elapsed="$((SECONDS - build_start))"

[[ -x "$RUNNER" ]] || die "runtime build did not produce executable: $RUNNER"
file "$RUNNER" > "$RUNNER_FILE_REPORT"
"$RV_READELF" -h "$RUNNER" > "$RUNNER_READELF_H"
"$RV_READELF" -A "$RUNNER" > "$RUNNER_READELF_A"
"$RV_READELF" -d "$RUNNER" > "$RUNNER_READELF_D"

grep -F 'ELF 64-bit LSB' "$RUNNER_FILE_REPORT" >/dev/null ||
    die "runner is not an ELF 64-bit LSB executable"
grep -F 'UCB RISC-V' "$RUNNER_FILE_REPORT" >/dev/null ||
    die "runner is not identified as RISC-V"
grep -E 'Class:[[:space:]]+ELF64' "$RUNNER_READELF_H" >/dev/null ||
    die "runner ELF header is not ELF64"
grep -E 'Machine:[[:space:]]+RISC-V' "$RUNNER_READELF_H" >/dev/null ||
    die "runner ELF header is not RISC-V"

if [[ "$RUNTIME_LINKAGE" == static ]]; then
    grep -F 'statically linked' "$RUNNER_FILE_REPORT" >/dev/null ||
        die "static runner is not reported as statically linked"
    if grep -F 'NEEDED' "$RUNNER_READELF_D" >/dev/null; then
        die "static runner unexpectedly has dynamic NEEDED entries"
    fi
fi

RUNNER_SHA256="$(sha256_of "$RUNNER")"
printf '%s  iree-run-module\n' "$RUNNER_SHA256" > "$RUNNER_SIDECAR"
mapfile -t runner_sidecar_lines < "$RUNNER_SIDECAR"
[[ "${#runner_sidecar_lines[@]}" -eq 1 \
        && "${runner_sidecar_lines[0]}" == "$RUNNER_SHA256  iree-run-module" ]] ||
    die "runner SHA-256 sidecar is malformed: $RUNNER_SIDECAR"

serialize_command()
{
    local serialized
    printf -v serialized '%q ' "$@"
    [[ "$serialized" != *$'\n'* ]] || die "serialized command contains a newline"
    printf '%s' "$serialized"
}

CONFIGURE_COMMAND_SERIALIZED="$(serialize_command "${CONFIGURE_COMMAND[@]}")"
BUILD_COMMAND_SERIALIZED="$(serialize_command "${BUILD_COMMAND[@]}")"

printf '%s\n' \
    "REPOSITORY_COMMIT=$REPOSITORY_COMMIT" \
    "IREE_REVISION=$IREE_REVISION" \
    "RUNTIME_LINKAGE=$RUNTIME_LINKAGE" \
    "CONFIG_SHA256=$CONFIG_SHA256" \
    "SOURCE_SHA256=$TENSOR_SOURCE_SHA256" \
    "COMPILE_MANIFEST_SHA256=$COMPILE_MANIFEST_SHA256" \
    "CONFIGURE_COMMAND=$CONFIGURE_COMMAND_SERIALIZED" \
    "BUILD_COMMAND=$BUILD_COMMAND_SERIALIZED" \
    "RUNNER_SHA256=$RUNNER_SHA256" \
    > "$RUNTIME_MANIFEST"

runtime_manifest_keys=(
    REPOSITORY_COMMIT IREE_REVISION RUNTIME_LINKAGE CONFIG_SHA256 SOURCE_SHA256
    COMPILE_MANIFEST_SHA256 CONFIGURE_COMMAND BUILD_COMMAND RUNNER_SHA256
)
declare -A runtime_values=()
parse_manifest "$RUNTIME_MANIFEST" runtime_values "${runtime_manifest_keys[@]}"

[[ "${runtime_values[REPOSITORY_COMMIT]}" == "$REPOSITORY_COMMIT" ]] ||
    die "runtime manifest repository commit mismatch"
[[ "${runtime_values[IREE_REVISION]}" == "$IREE_REVISION" ]] ||
    die "runtime manifest IREE revision mismatch"
[[ "${runtime_values[RUNTIME_LINKAGE]}" == "$RUNTIME_LINKAGE" ]] ||
    die "runtime manifest linkage mismatch"
[[ "${runtime_values[CONFIG_SHA256]}" == "$CONFIG_SHA256" ]] ||
    die "runtime manifest configuration hash mismatch"
[[ "${runtime_values[SOURCE_SHA256]}" == "$TENSOR_SOURCE_SHA256" ]] ||
    die "runtime manifest source hash mismatch"
[[ "${runtime_values[COMPILE_MANIFEST_SHA256]}" == "$COMPILE_MANIFEST_SHA256" ]] ||
    die "runtime manifest compile-manifest hash mismatch"
[[ "${runtime_values[CONFIGURE_COMMAND]}" == "$CONFIGURE_COMMAND_SERIALIZED" ]] ||
    die "runtime manifest configure command mismatch"
[[ "${runtime_values[BUILD_COMMAND]}" == "$BUILD_COMMAND_SERIALIZED" ]] ||
    die "runtime manifest build command mismatch"
[[ "${runtime_values[RUNNER_SHA256]}" == "$RUNNER_SHA256" ]] ||
    die "runtime manifest runner hash mismatch"

size_of()
{
    local size ignored
    read -r size ignored < <(du -sh "$1")
    printf '%s' "$size"
}

DEPENDENCIES_SIZE="$(size_of "$DEPS_DIR")"
SOURCE_SIZE="$(size_of "$SOURCE_DIR")"
BUILD_TREE_SIZE="$(size_of "$BUILD_DIR")"
RUNNER_SIZE="$(size_of "$RUNNER")"
VMFB_SIZE="$(size_of "$SCALAR_VMFB")"

printf '%s\n' \
    "RUNTIME_LINKAGE=$RUNTIME_LINKAGE" \
    "JOBS=$JOBS" \
    "CONFIGURE_ELAPSED_SECONDS=$configure_elapsed" \
    "BUILD_ELAPSED_SECONDS=$build_elapsed" \
    "DEPENDENCIES_SIZE=$DEPENDENCIES_SIZE" \
    "SOURCE_SIZE=$SOURCE_SIZE" \
    "BUILD_TREE_SIZE=$BUILD_TREE_SIZE" \
    "RUNNER_SIZE=$RUNNER_SIZE" \
    "VMFB_SIZE=$VMFB_SIZE" \
    > "$RESOURCE_REPORT"

printf '\nScalar RISC-V runtime build passed.\n'
printf 'Runner:           %s\n' "$RUNNER"
printf 'Runner SHA-256:   %s\n' "$RUNNER_SHA256"
printf 'Runtime manifest: %s\n' "$RUNTIME_MANIFEST"
printf 'Resource report:  %s\n' "$RESOURCE_REPORT"
printf 'Configure seconds: %s\n' "$configure_elapsed"
printf 'Build seconds:     %s\n' "$build_elapsed"
