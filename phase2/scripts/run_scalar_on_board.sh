#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    printf 'Usage: run_scalar_on_board.sh\n' >&2
    printf 'Environment:\n' >&2
    printf '  BOARD_HOST=<ssh host>            (default: orangepi-rv2)\n' >&2
    printf '  RUNTIME_LINKAGE=dynamic|static  (default: dynamic)\n' >&2
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

for command_name in git ssh scp grep sha256sum tee; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required local command not found: $command_name"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this command from inside the Git repository"
cd "$REPO_ROOT"

BOARD_HOST="${BOARD_HOST:-orangepi-rv2}"
RUNTIME_LINKAGE="${RUNTIME_LINKAGE:-dynamic}"
SSH_OPTIONS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
)

CONFIG_FILE="phase2/config/iree.env"
TENSOR_SOURCE="phase2/mlir/tensor_add.mlir"
DEPS_DIR="build/phase2/deps"
HOST_MARKER="$DEPS_DIR/iree-host/.phase2-dependency"
TOOLCHAIN_MARKER="$DEPS_DIR/riscv-toolchain/.phase2-dependency"
SCALAR_VMFB="build/phase2/scalar/tensor_add.vmfb"
SCALAR_SIDECAR="$SCALAR_VMFB.sha256"
COMPILE_MANIFEST="build/phase2/compile-manifest.txt"
TOOLCHAIN_VERSIONS="build/phase2/toolchain-versions.txt"

[[ -f "$CONFIG_FILE" ]] || die "missing configuration: $CONFIG_FILE"
# shellcheck source=../config/iree.env
. "$CONFIG_FILE"

required_config_keys=(
    IREE_REVISION
    IREE_HOST_ARCHIVE
    IREE_HOST_SHA256
    RISCV_TOOLCHAIN_ARCHIVE
    RISCV_TOOLCHAIN_SHA256
)
for config_key in "${required_config_keys[@]}"; do
    [[ -n "${!config_key:-}" ]] ||
        die "missing or empty configuration value: $config_key"
done

case "$RUNTIME_LINKAGE" in
    dynamic)
        BUILD_DIR="build/phase2/runtime-riscv64"
        RUNTIME_MANIFEST="build/phase2/runtime-manifest.txt"
        BOARD_LOG="build/phase2/board-run-dynamic.txt"
        ;;
    static)
        BUILD_DIR="build/phase2/runtime-riscv64-static"
        RUNTIME_MANIFEST="build/phase2/runtime-manifest-static.txt"
        BOARD_LOG="build/phase2/board-run-static.txt"
        ;;
    *)
        die "RUNTIME_LINKAGE must be dynamic or static, got: $RUNTIME_LINKAGE"
        ;;
esac

RUNNER="$BUILD_DIR/tools/iree-run-module"
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

verify_dependency_marker "$HOST_MARKER" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" host
verify_dependency_marker "$TOOLCHAIN_MARKER" \
    "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256" RISC-V-toolchain

for required_file in \
        "$TENSOR_SOURCE" "$SCALAR_VMFB" "$SCALAR_SIDECAR" \
        "$COMPILE_MANIFEST" "$RUNTIME_MANIFEST" "$TOOLCHAIN_VERSIONS" \
        "$RUNNER" "$RUNNER_SIDECAR"; do
    [[ -f "$required_file" ]] || die "missing required artifact: $required_file"
done
[[ -x "$RUNNER" ]] || die "runner is not executable: $RUNNER"
[[ -s "$SCALAR_VMFB" ]] || die "scalar VMFB is empty: $SCALAR_VMFB"
[[ -s "$TOOLCHAIN_VERSIONS" ]] || die "toolchain version report is empty: $TOOLCHAIN_VERSIONS"

compile_manifest_keys=(
    REPOSITORY_COMMIT IREE_REVISION CONFIG_SHA256 SOURCE_SHA256
    HOST_COMMAND SCALAR_COMMAND HOST_VMFB_SHA256 SCALAR_VMFB_SHA256
)
runtime_manifest_keys=(
    REPOSITORY_COMMIT IREE_REVISION RUNTIME_LINKAGE CONFIG_SHA256 SOURCE_SHA256
    COMPILE_MANIFEST_SHA256 CONFIGURE_COMMAND BUILD_COMMAND RUNNER_SHA256
)
declare -A compile_values=()
declare -A runtime_values=()
parse_manifest "$COMPILE_MANIFEST" compile_values "${compile_manifest_keys[@]}"
parse_manifest "$RUNTIME_MANIFEST" runtime_values "${runtime_manifest_keys[@]}"

CURRENT_COMMIT="$(git rev-parse HEAD)"
CONFIG_SHA256="$(sha256_of "$CONFIG_FILE")"
SOURCE_SHA256="$(sha256_of "$TENSOR_SOURCE")"
COMPILE_MANIFEST_SHA256="$(sha256_of "$COMPILE_MANIFEST")"
SCALAR_VMFB_SHA256="$(sha256_of "$SCALAR_VMFB")"
RUNNER_SHA256="$(sha256_of "$RUNNER")"

[[ "${compile_values[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" ]] ||
    die "compile manifest repository commit is stale; rerun compile_tensor_add.sh"
[[ "${compile_values[IREE_REVISION]}" == "$IREE_REVISION" ]] ||
    die "compile manifest IREE revision mismatch"
[[ "${compile_values[CONFIG_SHA256]}" == "$CONFIG_SHA256" ]] ||
    die "compile manifest configuration hash is stale"
[[ "${compile_values[SOURCE_SHA256]}" == "$SOURCE_SHA256" ]] ||
    die "compile manifest source hash is stale"
[[ "${compile_values[SCALAR_VMFB_SHA256]}" == "$SCALAR_VMFB_SHA256" ]] ||
    die "scalar VMFB digest does not match compile manifest"
[[ -n "${compile_values[HOST_COMMAND]}" && -n "${compile_values[SCALAR_COMMAND]}" ]] ||
    die "compile manifest contains an empty command"

[[ "${runtime_values[REPOSITORY_COMMIT]}" == "$CURRENT_COMMIT" ]] ||
    die "runtime manifest repository commit is stale; rerun build_riscv_runtime.sh"
[[ "${runtime_values[IREE_REVISION]}" == "$IREE_REVISION" ]] ||
    die "runtime manifest IREE revision mismatch"
[[ "${runtime_values[RUNTIME_LINKAGE]}" == "$RUNTIME_LINKAGE" ]] ||
    die "runtime manifest linkage mismatch"
[[ "${runtime_values[CONFIG_SHA256]}" == "$CONFIG_SHA256" ]] ||
    die "runtime manifest configuration hash is stale"
[[ "${runtime_values[SOURCE_SHA256]}" == "$SOURCE_SHA256" ]] ||
    die "runtime manifest source hash is stale"
[[ "${runtime_values[COMPILE_MANIFEST_SHA256]}" == "$COMPILE_MANIFEST_SHA256" ]] ||
    die "runtime manifest compile-manifest hash is stale"
[[ "${runtime_values[RUNNER_SHA256]}" == "$RUNNER_SHA256" ]] ||
    die "runner digest does not match runtime manifest"
[[ -n "${runtime_values[CONFIGURE_COMMAND]}" && -n "${runtime_values[BUILD_COMMAND]}" ]] ||
    die "runtime manifest contains an empty command"

mapfile -t scalar_sidecar_lines < "$SCALAR_SIDECAR"
[[ "${#scalar_sidecar_lines[@]}" -eq 1 \
        && "${scalar_sidecar_lines[0]}" == "$SCALAR_VMFB_SHA256  tensor_add.vmfb" ]] ||
    die "scalar VMFB sidecar is malformed or stale: $SCALAR_SIDECAR"
mapfile -t runner_sidecar_lines < "$RUNNER_SIDECAR"
[[ "${#runner_sidecar_lines[@]}" -eq 1 \
        && "${runner_sidecar_lines[0]}" == "$RUNNER_SHA256  iree-run-module" ]] ||
    die "runner sidecar is malformed or stale: $RUNNER_SIDECAR"

if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    die "the working tree is not clean; review, commit, and push Phase 2 first"
fi

printf 'Checking origin for current commit...\n'
git remote get-url origin >/dev/null 2>&1 || die "the repository does not have an origin remote"
git fetch origin --prune --quiet
if ! git branch --remotes --contains "$CURRENT_COMMIT" | grep -q 'origin/'; then
    die "commit $CURRENT_COMMIT has not been pushed to origin"
fi

printf '\nBoard:            %s\n' "$BOARD_HOST"
printf 'Commit:           %s\n' "$CURRENT_COMMIT"
printf 'IREE revision:    %s\n' "$IREE_REVISION"
printf 'Runtime linkage:  %s\n' "$RUNTIME_LINKAGE"
printf 'Runner SHA-256:   %s\n' "$RUNNER_SHA256"
printf 'VMFB SHA-256:     %s\n' "$SCALAR_VMFB_SHA256"

remote_output=''
set +e
remote_output="$(ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" \
    'mktemp -d /tmp/rvv-iree-lab-phase2.XXXXXX' 2>&1)"
remote_status="$?"
set -e
[[ "$remote_status" -eq 0 ]] || die "remote mktemp failed: $remote_output"
[[ "$remote_output" != *$'\n'* \
        && "$remote_output" =~ ^/tmp/rvv-iree-lab-phase2\.[A-Za-z0-9]+$ ]] ||
    die "remote mktemp returned an unsafe or malformed path: $remote_output"
REMOTE_DIR="$remote_output"

cleanup_remote()
{
    local primary_status="$?"
    trap - EXIT
    if [[ -n "${REMOTE_DIR:-}" ]]; then
        if ! ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- "$REMOTE_DIR" <<'REMOTE_CLEANUP'
set -Eeuo pipefail
remote_dir="$1"
case "$remote_dir" in
    /tmp/rvv-iree-lab-phase2.*) ;;
    *) exit 2 ;;
esac
rm -rf -- "$remote_dir"
REMOTE_CLEANUP
        then
            printf 'error: failed to clean remote directory: %s\n' "$REMOTE_DIR" >&2
            if [[ "$primary_status" -eq 0 ]]; then
                primary_status=1
            fi
        fi
    fi
    exit "$primary_status"
}
trap cleanup_remote EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

printf 'Remote directory: %s\n' "$REMOTE_DIR"
printf 'Transferring validated artifacts...\n'
scp "${SSH_OPTIONS[@]}" \
    "$RUNNER" \
    "$RUNNER_SIDECAR" \
    "$SCALAR_VMFB" \
    "$SCALAR_SIDECAR" \
    "$COMPILE_MANIFEST" \
    "$RUNTIME_MANIFEST" \
    "$TOOLCHAIN_VERSIONS" \
    "$BOARD_HOST:$REMOTE_DIR/"

printf 'Executing scalar tensor add on board...\n'
ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- \
    "$REMOTE_DIR" "$RUNTIME_LINKAGE" 2>&1 <<'REMOTE_EXECUTION' | tee "$BOARD_LOG"
set -Eeuo pipefail

remote_dir="$1"
runtime_linkage="$2"
cd "$remote_dir"

remote_die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for command_name in rm chmod sha256sum uname cat file; do
    command -v "$command_name" >/dev/null 2>&1 ||
        remote_die "required board command not found: $command_name"
done
if [[ "$runtime_linkage" == dynamic ]]; then
    command -v ldd >/dev/null 2>&1 || remote_die "required board command not found: ldd"
elif [[ "$runtime_linkage" != static ]]; then
    remote_die "invalid runtime linkage: $runtime_linkage"
fi

sha256sum --check iree-run-module.sha256
sha256sum --check tensor_add.vmfb.sha256
chmod 0755 iree-run-module

printf '\n== board uname ==\n'
uname -a
[[ "$(uname -m)" == riscv64 ]] || remote_die "board architecture is not riscv64"
printf '\n== board os-release ==\n'
cat /etc/os-release

printf '\n== runner file ==\n'
runner_file="$(file ./iree-run-module)"
printf '%s\n' "$runner_file"
[[ "$runner_file" == *'ELF 64-bit LSB'* ]] || remote_die "runner is not ELF 64-bit LSB"
[[ "$runner_file" == *'UCB RISC-V'* ]] || remote_die "runner is not RISC-V"

printf '\n== VMFB file ==\n'
file ./tensor_add.vmfb

if [[ "$runtime_linkage" == dynamic ]]; then
    printf '\n== board ldd version ==\n'
    ldd --version 2>&1 || true
    printf '\n== runner dependencies ==\n'
    ldd_output="$(ldd ./iree-run-module 2>&1)" || remote_die "ldd failed: $ldd_output"
    printf '%s\n' "$ldd_output"
    [[ "$ldd_output" != *'not found'* ]] || remote_die "runner has a missing dynamic dependency"
else
    [[ "$runner_file" == *'statically linked'* ]] || remote_die "runner is not statically linked"
    printf '\nStatic runner: ldd skipped.\n'
fi

printf '\n== tensor-add execution ==\n'
./iree-run-module \
    --device=local-task \
    --module=tensor_add.vmfb \
    --function=add \
    --input='4xf32=1 2 3 4' \
    --input='4xf32=10 20 30 40' \
    --expected_output='4xf32=11 22 33 44'
REMOTE_EXECUTION

grep -F '[SUCCESS] all function outputs matched their expected values.' \
    "$BOARD_LOG" >/dev/null || die "board log does not contain the expected success line"

printf '\nScalar board validation passed.\n'
printf 'Board log: %s\n' "$BOARD_LOG"
