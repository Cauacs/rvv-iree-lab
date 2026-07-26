#!/usr/bin/env bash
#
# Prepare Phase 2's pinned IREE toolchain under build/phase2/deps/ without
# modifying the working tree outside build/. Produces:
#
#   build/phase2/deps/downloads/<archives>            verified downloaded archives
#   build/phase2/deps/iree-host/                      pin-verified host distribution
#   build/phase2/deps/riscv-toolchain/                pin-verified RISC-V Clang sysroot
#   build/phase2/deps/iree-src/                       runtime-only IREE source at IREE_REVISION
#   build/phase2/deps/iree-source-version.txt         all top-level submodule gitlinks
#   build/phase2/toolchain-versions.txt               host/target toolchain version dump
#
# Authoritative values come only from phase2/config/iree.env. Reuse of a final
# directory is permitted only when its .phase2-dependency marker and required
# paths match the configuration; any missing or mismatched state is a hard error.

set -Eeuo pipefail

usage()
{
    printf 'Usage: prepare_iree.sh\n' >&2
    printf 'Environment:\n' >&2
    printf '  (none; all values come from phase2/config/iree.env)\n' >&2
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Reject positional arguments (FOO=bar env assignments are allowed by bash and
# never reach "$@", so this only blocks real positional usage).
if [[ "$#" -ne 0 ]]; then
    usage
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this command from inside the Git repository"
cd "$REPO_ROOT"

required_commands=(
    git curl sha256sum tar cmake ninja python3 uname cc du
)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

# Source only the approved configuration; nothing else.
# shellcheck source=../config/iree.env
. "$REPO_ROOT/phase2/config/iree.env"

DEPS_DIR="$REPO_ROOT/build/phase2/deps"
DOWNLOADS_DIR="$DEPS_DIR/downloads"
HOST_DIR="$DEPS_DIR/iree-host"
TOOLCHAIN_DIR="$DEPS_DIR/riscv-toolchain"
SOURCE_DIR="$DEPS_DIR/iree-src"
SOURCE_VERSION_FILE="$DEPS_DIR/iree-source-version.txt"
TOOLCHAIN_VERSIONS_FILE="$REPO_ROOT/build/phase2/toolchain-versions.txt"

mkdir -p "$DOWNLOADS_DIR"

# ---------------------------------------------------------------------------
# Download + verify a configured archive into build/phase2/deps/downloads/.
# A .part file is never trusted or resumed: a wrong hash is a hard error.
# ---------------------------------------------------------------------------
download_verified()
{
    local url="$1"
    local archive="$2"
    local expected_sha256="$3"

    local final="$DOWNLOADS_DIR/$archive"
    local part="$final.part"

    if [[ -f "$final" ]]; then
        local actual
        actual="$(sha256sum "$final" | awk '{print $1}')"
        if [[ "$actual" == "$expected_sha256" ]]; then
            printf 'download: reuse verified %s\n' "$archive"
            return 0
        fi
        die "existing $final has wrong hash: expected $expected_sha256, got $actual"

    fi
    printf 'download: %s -> %s\n' "$url" "$final"
    rm -f "$part"
    # --fail with --location makes non-2xx a hard error; the .part may be left
    # behind on failure, but we never publish it.
    curl --fail --location --output "$part" \
        --connect-timeout 30 --retry 0 \
        "$url" \
        || die "download failed for $url"

    local actual
    actual="$(sha256sum "$part" | awk '{print $1}')"
    if [[ "$actual" != "$expected_sha256" ]]; then
        rm -f "$part"
        die "downloaded $archive hash mismatch: expected $expected_sha256, got $actual"
    fi

    mv -f "$part" "$final"
    printf 'download: verified %s\n' "$archive"
}

# ---------------------------------------------------------------------------
# Atomically install a dependency directory from a staging tree.
#   install_dep <final_dir> <staging_dir> <archive> <sha256> <req_path>...
# Reuse is allowed ONLY if the existing marker records the same archive/sha256
# AND every requested path exists relative to the final dir. Otherwise:
#   - marker absent  -> fresh build (rm+publish)
#   - marker present but mismatched or paths missing -> hard error (do not try)
# ---------------------------------------------------------------------------
install_dep()
{
    local final_dir="$1"
    local staging_dir="$2"
    local archive="$3"
    local sha256="$4"
    shift 4
    local required_paths=("$@")

    local marker="$final_dir/.phase2-dependency"

    if [[ -e "$marker" ]]; then
        if [[ -f "$marker" ]]; then
            local m_archive m_sha256
            m_archive="$(awk -F= '$1=="archive" {print $2; exit}' "$marker")"
            m_sha256="$(awk -F= '$1=="sha256" {print $2; exit}' "$marker")"
            if [[ "$m_archive" == "$archive" && "$m_sha256" == "$sha256" ]]; then
                local all_missing=0
                local p
                for p in "${required_paths[@]}"; do
                    [[ -e "$final_dir/$p" ]] || all_missing=1
                done
                if [[ "$all_missing" -eq 0 ]]; then
                    printf 'reuse: %s matches archive and required paths\n' "$final_dir"
                    rm -rf "$staging_dir"
                    return 0
                fi
                die "$final_dir marker matches but a required path is missing; rerun after removing $final_dir"
            fi
            die "$final_dir has a mismatched .phase2-dependency marker; rerun after removing $final_dir"
        fi
        die "$final_dir has a non-regular .phase2-dependency; rerun after removing $final_dir"
    fi

    if [[ -e "$final_dir" ]]; then
        die "$final_dir exists without a valid marker; rerun after removing $final_dir"
    fi

    printf 'install: publishing %s\n' "$final_dir"
    printf 'archive=%s\nsha256=%s\n' "$archive" "$sha256" > "$staging_dir/.phase2-dependency"
    mv -f "$staging_dir" "$final_dir"
}

# ---------------------------------------------------------------------------
# Verify a release directory already exists with the marker and required paths.
# Used in headers other than install_dep so the prepare flow can short-circuit
# reuse without staging a fresh tree.
# ---------------------------------------------------------------------------
verify_present()
{
    local final_dir="$1"
    local archive="$2"
    local sha256="$3"
    shift 3
    local required_paths=("$@")
    local marker="$final_dir/.phase2-dependency"

    [[ -f "$marker" ]] || return 1
    local m_archive m_sha256
    m_archive="$(awk -F= '$1=="archive" {print $2; exit}' "$marker")"
    m_sha256="$(awk -F= '$1=="sha256" {print $2; exit}' "$marker")"
    [[ "$m_archive" == "$archive" && "$m_sha256" == "$sha256" ]] || return 1
    local p
    for p in "${required_paths[@]}"; do
        [[ -e "$final_dir/$p" ]] || return 1
    done
    return 0
}

# Pending staging directories, cleaned on any exit. Successful publish routes
# remove the path before the trap runs, so the guarded `rm -rf` is a no-op. An
# interrupted/interrupted cleanup leaves no half-built dependency on disk.
STAGING_DIRS=()
cleanup_staging()
{
    local p
    for p in "${STAGING_DIRS[@]}"; do
        [[ -n "$p" && -d "$p" ]] && rm -rf -- "$p"
    done
}
trap cleanup_staging EXIT INT TERM HUP

# start_stage <final_dir> -> allocates a fresh sibling staging dir, registers
# it for cleanup, and echoes its absolute path on stdout. Never names it
# <final_dir> so a crash before publish cannot be mistaken for the final tree.
start_stage()
{
    local final_dir="$1"
    local stage="$final_dir.stage.$$"
    rm -rf "$stage"
    mkdir -p "$stage"
    STAGING_DIRS+=("$stage")
    printf '%s' "$stage"
}

# ---------------------------------------------------------------------------
# 1. Host distribution: download, verify, extract, publish iree-host/.
# ---------------------------------------------------------------------------
printf '\n== phase2/prepare: host distribution ==\n'
host_required=(bin/iree-compile bin/iree-run-module bin/iree-dump-module)
if verify_present "$HOST_DIR" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" \
        "${host_required[@]}"; then
    printf 'reuse: %s\n' "$HOST_DIR"
else
    download_verified "$IREE_HOST_URL" "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256"
    host_stage="$(start_stage "$HOST_DIR")"
    tar -xf "$DOWNLOADS_DIR/$IREE_HOST_ARCHIVE" -C "$host_stage" \
        || die "host extraction failed"
    install_dep "$HOST_DIR" "$host_stage" \
        "$IREE_HOST_ARCHIVE" "$IREE_HOST_SHA256" "${host_required[@]}"
fi
IREE_COMPILE="$HOST_DIR/bin/iree-compile"
IREE_RUN_MODULE="$HOST_DIR/bin/iree-run-module"
IREE_DUMP_MODULE="$HOST_DIR/bin/iree-dump-module"
[[ -x "$IREE_COMPILE" ]] || die "missing executable: $IREE_COMPILE"
[[ -x "$IREE_RUN_MODULE" ]] || die "missing executable: $IREE_RUN_MODULE"
[[ -x "$IREE_DUMP_MODULE" ]] || die "missing executable: $IREE_DUMP_MODULE"

# ---------------------------------------------------------------------------
# 2. RISC-V toolchain: download, verify, extract (--strip-components=1),
#    publish riscv-toolchain/.
# ---------------------------------------------------------------------------
printf '\n== phase2/prepare: RISC-V toolchain ==\n'
toolchain_required=(bin/clang bin/clang++ bin/riscv64-unknown-linux-gnu-readelf sysroot)
if verify_present "$TOOLCHAIN_DIR" "$RISCV_TOOLCHAIN_ARCHIVE" \
        "$RISCV_TOOLCHAIN_SHA256" "${toolchain_required[@]}"; then
    printf 'reuse: %s\n' "$TOOLCHAIN_DIR"
else
    download_verified "$RISCV_TOOLCHAIN_URL" \
        "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256"
    tc_stage="$(start_stage "$TOOLCHAIN_DIR")"
    tar -xzf "$DOWNLOADS_DIR/$RISCV_TOOLCHAIN_ARCHIVE" \
        --strip-components=1 -C "$tc_stage" \
        || die "toolchain extraction failed"
    install_dep "$TOOLCHAIN_DIR" "$tc_stage" \
        "$RISCV_TOOLCHAIN_ARCHIVE" "$RISCV_TOOLCHAIN_SHA256" \
        "${toolchain_required[@]}"
fi

RV_CLANG="$TOOLCHAIN_DIR/bin/clang"
RV_CLANGXX="$TOOLCHAIN_DIR/bin/clang++"
RV_READELF="$TOOLCHAIN_DIR/bin/riscv64-unknown-linux-gnu-readelf"
RV_SYSROOT="$TOOLCHAIN_DIR/sysroot"
[[ -x "$RV_CLANG"   ]] || die "missing executable: $RV_CLANG"
[[ -x "$RV_CLANGXX" ]] || die "missing executable: $RV_CLANGXX"
[[ -x "$RV_READELF" ]] || die "missing executable: $RV_READELF"
[[ -d "$RV_SYSROOT" ]] || die "missing sysroot: $RV_SYSROOT"

# ---------------------------------------------------------------------------
# 3. Runtime-only IREE source: non-recursive clone of IREE_REVISION, init only
#    runtime_submodules.txt paths, validate HEAD + submodule status, then
#    atomically publish iree-src/.
# ---------------------------------------------------------------------------
printf '\n== phase2/prepare: IREE source (runtime only) ==\n'

source_check_passed()
{
    local src="$1"
    (
        cd "$src"
        # HEAD must equal the pinned revision exactly.
        local head
        head="$(git rev-parse HEAD)"
        [[ "$head" == "$IREE_REVISION" ]] || return 1

        local rsm="$src/build_tools/scripts/git/runtime_submodules.txt"
        [[ -f "$rsm" ]] || return 1

        # Initialize only runtime submodules; never fetch compiler/LLVM paths.
        while IFS= read -r line; do
            # strip comments and blanks
            line="${line%%#*}"
            line="${line//[$'\t\r ']/}"
            [[ -n "$line" ]] || continue
            git submodule update --init --depth 1 -- "$line" >/dev/null 2>&1 \
                || return 1
        done < "$rsm"

        # Each runtime path's submodule status must begin with a space.
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line//[$'\t\r ']/}"
            [[ -n "$line" ]] || continue
            local status
            status="$(git submodule status -- "$line")"
            [[ "$status" == $'\n'* ]] && status="${status#*$'\n'}"
            # `git submodule status` prefixes: ' '=inited, '-'=uninited,
            # '+'=wrong commit, 'U'=merge conflict.
            case "${status:0:1}" in
                ' ') ;;
                *)  return 1 ;;
            esac
        done < "$rsm"

        python3 "$src/build_tools/scripts/git/check_submodule_init.py" --runtime_only \
            >/dev/null 2>&1 || return 1
    )
}

if [[ -d "$SOURCE_DIR/.git" ]] \
        && source_check_passed "$SOURCE_DIR"; then
    printf 'reuse: %s\n' "$SOURCE_DIR"
else
    # If a stale source dir exists but failed the check, hard error: do not
    # silently re-clone over a possibly-user-touched tree.
    if [[ -e "$SOURCE_DIR" ]]; then
        die "$SOURCE_DIR exists but failed source checks; rerun after removing it"
    fi
    src_stage="$(start_stage "$SOURCE_DIR")"

    # Clone without recursive submodules; the top-level EXIT cleanup trap owns
    # src_stage, so no subshell trap is needed (and one would delete the tree
    # we are about to publish on a successful exit).
    git clone --no-checkout "$IREE_SOURCE_URL" "$src_stage" \
        || die "git clone of IREE source failed"
    git -C "$src_stage" checkout "$IREE_REVISION" \
        || die "git checkout of IREE_REVISION failed"

    source_check_passed "$src_stage" \
        || die "pinned source failed HEAD/submodule checks at $IREE_REVISION"

    mv -f "$src_stage" "$SOURCE_DIR"
fi

# Capture all top-level submodule statuses. Compiler-only entries remain
# uninitialized (prefix '-') so their gitlinks are recorded without fetching.
{
    git -C "$SOURCE_DIR" submodule status
} > "$SOURCE_VERSION_FILE"
[[ -s "$SOURCE_VERSION_FILE" ]] \
    || die "git submodule status produced no output"

# ---------------------------------------------------------------------------
# 4. Toolchain/version dump + required-CLI-flag presence check.
# ---------------------------------------------------------------------------
printf '\n== phase2/prepare: versions and required flags ==\n'
{
    printf '# Generated by phase2/scripts/prepare_iree.sh\n'
    printf '## ctime: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '## host uname\n%s\n\n' "$(uname -a)"

    printf '## /etc/os-release\n'
    if [[ -f /etc/os-release ]]; then
        cat /etc/os-release
    else
        printf '(no /etc/os-release)\n'
    fi
    printf '\n'

    printf '## iree-compile --version\n%s\n\n' \
        "$("$IREE_COMPILE" --version 2>&1 || true)"

    printf '## iree-run-module --help\n%s\n\n' \
        "$("$IREE_RUN_MODULE" --help 2>&1 || true)"

    printf '## cmake --version\n%s\n\n' "$(cmake --version 2>&1 | head -n1)"
    printf '## ninja --version\n%s\n\n' "$(ninja --version 2>&1)"
    printf '## python3 --version\n%s\n\n' \
        "$(python3 --version 2>&1)"
    printf '## host cc --version\n%s\n\n' "$(cc --version 2>&1 | head -n1)"
    printf '## riscv clang --version\n%s\n\n' \
        "$("$RV_CLANG" --version 2>&1 | head -n1)"
    printf '## riscv linker --version\n%s\n\n' \
        "$("$RV_CLANG" --target=riscv64 -mabi=lp64d -Wl,--version 2>&1 \
            | head -n1 || true)"
} > "$TOOLCHAIN_VERSIONS_FILE"

# Required CLI flag literals must be present in compiler/runner help text.
required_compiler_flags=(
    --iree-hal-target-device
    --iree-hal-local-target-device-backends
    --iree-llvmcpu-target-triple
    --iree-llvmcpu-target-abi
    --iree-llvmcpu-target-cpu-features
    --iree-opt-level
)
missing_flags=()
for f in "${required_compiler_flags[@]}"; do
    if ! "$IREE_COMPILE" --help 2>&1 | grep -F -- "$f" >/dev/null 2>&1; then
        missing_flags+=("$f")
    fi
done
if ! "$IREE_RUN_MODULE" --help 2>&1 | grep -F -- '--expected_output' \
        >/dev/null 2>&1; then
    missing_flags+=('--expected_output (iree-run-module)')
fi
if [[ "${#missing_flags[@]}" -ne 0 ]]; then
    die "required CLI flags not found: ${missing_flags[*]}"
fi

printf '\n== phase2/prepare: done ==\n'
printf 'host=%s\n'      "$HOST_DIR"
printf 'toolchain=%s\n' "$TOOLCHAIN_DIR"
printf 'source=%s\n'    "$SOURCE_DIR"
printf 'versions=%s\n'  "$TOOLCHAIN_VERSIONS_FILE"
