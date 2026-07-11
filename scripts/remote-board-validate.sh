#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    cat >&2 <<'USAGE'
Usage:
  remote-board-validate.sh REPOSITORY_URL COMMIT_SHA

Environment:
  REMOTE_ROOT  Remote checkout directory.
               Default: $HOME/src/rvv-iree-lab

  BUILD_TYPE  CMake build type.
              Default: Release

  JOBS        Number of parallel build jobs.
              Default: 2
USAGE
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "$#" -ne 2 ]]; then
    usage
    exit 2
fi

REPOSITORY_URL="$1"
COMMIT_SHA="$2"

REMOTE_ROOT="${REMOTE_ROOT:-$HOME/src/rvv-iree-lab}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
JOBS="${JOBS:-2}"
BUILD_DIR="$REMOTE_ROOT/build/board"

if [[ ! "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "commit SHA must be a full 40-character lowercase hexadecimal SHA"
fi

case "$REPOSITORY_URL" in
    https://github.com/Cauacs/rvv-iree-lab.git)
        ;;
    *)
        die "unexpected repository URL: $REPOSITORY_URL"
        ;;
esac

for command in git cmake ninja cc ctest file; do
    command -v "$command" >/dev/null 2>&1 ||
        die "required board command not found: $command"
done

if [[ -e "$REMOTE_ROOT" && ! -d "$REMOTE_ROOT/.git" ]]; then
    die "$REMOTE_ROOT exists but is not a Git repository"
fi

if [[ ! -d "$REMOTE_ROOT/.git" ]]; then
    mkdir -p "$(dirname "$REMOTE_ROOT")"

    git clone \
        --no-checkout \
        "$REPOSITORY_URL" \
        "$REMOTE_ROOT"
fi

cd "$REMOTE_ROOT"

CURRENT_ORIGIN="$(git remote get-url origin)"

if [[ "$CURRENT_ORIGIN" != "$REPOSITORY_URL" ]]; then
    git remote set-url origin "$REPOSITORY_URL"
fi

git fetch \
    --force \
    --prune \
    origin \
    main

if ! git merge-base --is-ancestor "$COMMIT_SHA" origin/main; then
    die "commit $COMMIT_SHA is not reachable from origin/main"
fi

git checkout \
    --detach \
    --force \
    "$COMMIT_SHA"

git reset \
    --hard \
    "$COMMIT_SHA"

git clean \
    -fdx

cmake \
    -S . \
    -B "$BUILD_DIR" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

cmake \
    --build "$BUILD_DIR" \
    --parallel "$JOBS"

ctest \
    --test-dir "$BUILD_DIR" \
    --output-on-failure

"$BUILD_DIR/arch-info"

file "$BUILD_DIR/arch-info"

printf '\nBoard validation passed for commit %s\n' "$COMMIT_SHA"
