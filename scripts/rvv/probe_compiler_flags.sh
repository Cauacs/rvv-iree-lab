#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    printf 'Usage: probe_compiler_flags.sh\n' >&2
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

print_diagnostics()
{
    local path="$1"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '    %s\n' "$line"
    done < "$path"
}

print_skipped_stages()
{
    local first_stage="$1"

    case "$first_stage" in
        assemble)
            printf '  assemble: SKIP\n'
            ;&
        link)
            printf '  link: SKIP\n'
            ;&
        execute)
            printf '  execute: SKIP\n'
            ;;
        *)
            die "unknown skipped stage: $first_stage"
            ;;
    esac
}

cleanup()
{
    if [[ -n "${workspace:-}" && -d "$workspace" ]]; then
        rm -rf -- "$workspace"
    fi
}

if [[ "$#" -ne 0 ]]; then
    usage
    exit 2
fi

for command_name in cc grep mktemp; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

workspace=''
trap cleanup EXIT
workspace="$(mktemp -d)"
source_file="$workspace/probe.c"

printf '%s\n' \
    '#include <stddef.h>' \
    '#include <stdint.h>' \
    '#include <riscv_vector.h>' \
    '' \
    'int main(void)' \
    '{' \
    '    const int32_t lhs[4] = {1, 2, 3, 4};' \
    '    const int32_t rhs[4] = {10, 20, 30, 40};' \
    '    const int32_t expected[4] = {11, 22, 33, 44};' \
    '    int32_t result[4] = {0, 0, 0, 0};' \
    '    const size_t vl = __riscv_vsetvl_e32m1(4);' \
    '' \
    '    if (vl != 4) {' \
    '        return 1;' \
    '    }' \
    '' \
    '    const vint32m1_t lhs_vector = __riscv_vle32_v_i32m1(lhs, vl);' \
    '    const vint32m1_t rhs_vector = __riscv_vle32_v_i32m1(rhs, vl);' \
    '    const vint32m1_t sum_vector =' \
    '        __riscv_vadd_vv_i32m1(lhs_vector, rhs_vector, vl);' \
    '' \
    '    __riscv_vse32_v_i32m1(result, sum_vector, vl);' \
    '' \
    '    for (size_t index = 0; index < 4; ++index) {' \
    '        if (result[index] != expected[index]) {' \
    '            return 1;' \
    '        }' \
    '    }' \
    '' \
    '    return 0;' \
    '}' \
    > "$source_file"

march_values=(
    rv64gcv
    rv64gcv_zvl128b
    rv64imafdcv
    rv64gcv
)

mabi_values=(
    lp64d
    lp64d
    lp64d
    lp64
)

selection_eligible=(
    true
    true
    true
    false
)

selected_march=''
selected_mabi=''

for index in "${!march_values[@]}"; do
    march="${march_values[$index]}"
    mabi="${mabi_values[$index]}"
    prefix="$workspace/probe-$index"

    printf 'flags: -march=%s -mabi=%s\n' "$march" "$mabi"

    if cc \
        -std=c11 \
        -Wall \
        -Wextra \
        -Wpedantic \
        -Werror \
        "-march=$march" \
        "-mabi=$mabi" \
        -S \
        "$source_file" \
        -o "$prefix.s" \
        2> "$prefix.compile.stderr"; then
        printf '  compile: PASS\n'
    else
        printf '  compile: FAIL\n'
        print_diagnostics "$prefix.compile.stderr"
        print_skipped_stages assemble
        continue
    fi

    if cc \
        "-march=$march" \
        "-mabi=$mabi" \
        -c \
        "$prefix.s" \
        -o "$prefix.o" \
        2> "$prefix.assemble.stderr"; then
        printf '  assemble: PASS\n'
    else
        printf '  assemble: FAIL\n'
        print_diagnostics "$prefix.assemble.stderr"
        print_skipped_stages link
        continue
    fi

    if cc \
        "-march=$march" \
        "-mabi=$mabi" \
        "$prefix.o" \
        -o "$prefix" \
        2> "$prefix.link.stderr"; then
        printf '  link: PASS\n'
    else
        printf '  link: FAIL\n'
        print_diagnostics "$prefix.link.stderr"
        print_skipped_stages execute
        continue
    fi

    if "$prefix" \
        > "$prefix.execute.stdout" \
        2> "$prefix.execute.stderr"; then
        execute_status=0
        printf '  execute: PASS (exit=%d)\n' "$execute_status"
    else
        execute_status="$?"
        printf '  execute: FAIL (exit=%d)\n' "$execute_status"
        print_diagnostics "$prefix.execute.stderr"
        continue
    fi

    if [[ -z "$selected_march" && "${selection_eligible[$index]}" == true ]]; then
        selected_march="$march"
        selected_mabi="$mabi"
    fi
done

printf '\n'

if [[ -z "$selected_march" ]]; then
    printf 'selected: none\n'
    exit 1
fi

printf 'selected: -march=%s -mabi=%s\n' "$selected_march" "$selected_mabi"
printf '\nselected target macros:\n'

if ! cc \
    "-march=$selected_march" \
    "-mabi=$selected_mabi" \
    -dM \
    -E \
    -x c \
    -include riscv_vector.h \
    - \
    < /dev/null \
    > "$workspace/selected.macros" \
    2> "$workspace/selected.macros.stderr"; then
    print_diagnostics "$workspace/selected.macros.stderr"
    die 'failed to collect selected target macros'
fi

required_macros=(
    __riscv_v
    __riscv_vector
    __riscv_v_intrinsic
    __riscv_v_min_vlen
)

for macro_name in "${required_macros[@]}"; do
    if ! grep -Eq "^#define ${macro_name} " "$workspace/selected.macros"; then
        die "selected target macro missing: $macro_name"
    fi
done

grep -E \
    '^#define (__riscv_v|__riscv_vector|__riscv_v_intrinsic|__riscv_v_min_vlen) ' \
    "$workspace/selected.macros"
