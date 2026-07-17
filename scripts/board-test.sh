#!/usr/bin/env bash

set -Eeuo pipefail

BOARD_HOST="${BOARD_HOST:-orangepi-rv2}"
REMOTE_SUBDIR="${REMOTE_SUBDIR:-src/rvv-iree-lab}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-2}"

SSH_OPTIONS=(
    -o BatchMode=yes
    -o ConnectTimeout=10
)

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for command in git ssh grep; do
    command -v "$command" >/dev/null 2>&1 ||
        die "required local command not found: $command"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this command from inside the Git repository"

cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    die "the working tree is not clean; commit your changes first"
fi

COMMIT_SHA="$(git rev-parse HEAD)"

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" ||
    die "the repository does not have an origin remote"

printf 'Checking GitHub for the current commit...\n'
git fetch origin --prune --quiet

if ! git branch --remotes --contains "$COMMIT_SHA" |
    grep -q 'origin/'; then
    die "commit $COMMIT_SHA has not been pushed to origin"
fi

case "$ORIGIN_URL" in
    git@github.com:*)
        REPOSITORY_PATH="${ORIGIN_URL#git@github.com:}"
        ;;
    git@github-personal:*)
        REPOSITORY_PATH="${ORIGIN_URL#git@github-personal:}"
        ;;
    https://github.com/*)
        REPOSITORY_PATH="${ORIGIN_URL#https://github.com/}"
        ;;
    *)
        die "unsupported origin URL: $ORIGIN_URL"
        ;;
esac

REPOSITORY_URL="https://github.com/${REPOSITORY_PATH}"

printf '\n'
printf 'Board:      %s\n' "$BOARD_HOST"
printf 'Commit:     %s\n' "$COMMIT_SHA"
printf 'Repository: %s\n' "$REPOSITORY_URL"
printf 'Build type: %s\n' "$BUILD_TYPE"
printf 'Jobs:       %s\n' "$JOBS"
printf '\n'

printf 'Checking non-interactive SSH access...\n'

if ! ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" true; then
    die "cannot access $BOARD_HOST without interaction; configure SSH public-key authentication first"
fi

printf 'SSH access succeeded.\n\n'

ssh "${SSH_OPTIONS[@]}" "$BOARD_HOST" bash -s -- \
    "$REPOSITORY_URL" \
    "$COMMIT_SHA" \
    "$REMOTE_SUBDIR" \
    "$BUILD_TYPE" \
    "$JOBS" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

REPOSITORY_URL="$1"
COMMIT_SHA="$2"
REMOTE_SUBDIR="$3"
BUILD_TYPE="$4"
JOBS="$5"

REMOTE_DIR="$HOME/$REMOTE_SUBDIR"
BUILD_DIR="$REMOTE_DIR/build/board"

remote_die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_disassembly_mnemonic()
{
    local mnemonic="$1"
    local pattern="$2"
    local disassembly_path="$3"

    grep -Eq \
        "[[:space:]]${pattern}[[:space:]]" \
        "$disassembly_path" ||
        remote_die "RVV disassembly is missing $mnemonic"
}

for command in git cmake ninja cc ctest file grep objdump; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'error: missing board command: %s\n' "$command" >&2
        exit 1
    }
done

if [[ -e "$REMOTE_DIR" && ! -d "$REMOTE_DIR/.git" ]]; then
    printf 'error: %s exists but is not a Git repository\n' \
        "$REMOTE_DIR" >&2
    exit 1
fi

if [[ ! -d "$REMOTE_DIR/.git" ]]; then
    printf 'Cloning repository on board...\n'
    mkdir -p "$(dirname "$REMOTE_DIR")"
    git clone "$REPOSITORY_URL" "$REMOTE_DIR"
fi

cd "$REMOTE_DIR"

printf '\nFetching exact commit...\n'
git fetch origin --prune
git checkout --detach "$COMMIT_SHA"
git reset --hard "$COMMIT_SHA"
git clean -fdx

printf '\nCollecting RISC-V vector capabilities...\n'
scripts/rvv/collect_capabilities.sh

printf '\nProbing RISC-V vector compiler flags...\n'
scripts/rvv/probe_compiler_flags.sh

printf '\nConfiguring native RISC-V build...\n'
cmake \
    -S . \
    -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DENABLE_RVV_EXPERIMENTS=ON

printf '\nBuilding on Orange Pi...\n'
cmake \
    --build "$BUILD_DIR" \
    --parallel "$JOBS"

printf '\nRunning tests...\n'
ctest \
    --test-dir "$BUILD_DIR" \
    --output-on-failure

printf '\nRunning executable...\n'
"$BUILD_DIR/arch-info"

printf '\nExecutable information:\n'
file "$BUILD_DIR/arch-info"

printf '\nRunning RVV executable...\n'
"$BUILD_DIR/rvv_vector_add"

printf '\nRVV executable information:\n'
RVV_FILE_INFORMATION="$(file "$BUILD_DIR/rvv_vector_add")"
printf '%s\n' "$RVV_FILE_INFORMATION"

case "$RVV_FILE_INFORMATION" in
    *"ELF 64-bit LSB"*"UCB RISC-V"*)
        ;;
    *)
        remote_die \
            "rvv_vector_add is not a 64-bit RISC-V ELF executable"
        ;;
esac

RVV_DISASSEMBLY="$BUILD_DIR/rvv_vector_add.disasm"

objdump \
    -d \
    "$BUILD_DIR/rvv_vector_add" \
    > "$RVV_DISASSEMBLY"

require_disassembly_mnemonic \
    vsetvli \
    vsetvli \
    "$RVV_DISASSEMBLY"
require_disassembly_mnemonic \
    vle32.v \
    'vle32\.v' \
    "$RVV_DISASSEMBLY"
require_disassembly_mnemonic \
    vadd.vv \
    'vadd\.vv' \
    "$RVV_DISASSEMBLY"
require_disassembly_mnemonic \
    vse32.v \
    'vse32\.v' \
    "$RVV_DISASSEMBLY"

printf '\nRVV disassembly evidence:\n'
grep -E \
    '[[:space:]](vsetvli|vle32\.v|vadd\.vv|vse32\.v)[[:space:]]' \
    "$RVV_DISASSEMBLY"

printf '\nBoard validation passed for commit %s\n' "$COMMIT_SHA"
REMOTE_SCRIPT
