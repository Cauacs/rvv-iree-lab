#!/usr/bin/env bash

set -Eeuo pipefail

usage()
{
    printf 'Usage: collect_capabilities.sh\n' >&2
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

print_section()
{
    printf '\n=== %s ===\n' "$1"
}

print_unavailable()
{
    printf 'unavailable\n'
}

run_optional_command()
{
    local command_name="$1"
    shift

    if ! command -v "$command_name" >/dev/null 2>&1; then
        print_unavailable
        return
    fi

    if ! "$command_name" "$@" 2>&1; then
        print_unavailable
    fi
}

print_optional_file()
{
    local path="$1"

    printf '%s:\n' "$path"

    if [[ ! -r "$path" ]]; then
        print_unavailable
        return
    fi

    if ! cat "$path"; then
        print_unavailable
    fi
}

print_device_tree_property()
{
    local path="$1"

    printf '%s:\n' "$path"

    if [[ ! -r "$path" ]]; then
        print_unavailable
        return
    fi

    if ! tr '\0' '\n' < "$path"; then
        print_unavailable
    fi
}

if [[ "$#" -ne 0 ]]; then
    usage
    exit 2
fi

for command_name in uname cc cat tr; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

[[ -r /proc/cpuinfo ]] || die '/proc/cpuinfo is not readable'

print_section 'uname -a'
uname -a

print_section 'lscpu'
run_optional_command lscpu

print_section '/proc/cpuinfo'
cat /proc/cpuinfo

print_section 'cc --version'
cc --version

print_section 'cc -v'
cc -v 2>&1

print_section 'cc -Q --help=target'
cc -Q --help=target

print_section 'default compiler RISC-V predefined macros'
cc -dM -E -x c - < /dev/null

print_section 'userspace auxiliary vector'
if [[ ! -x /bin/true ]]; then
    print_unavailable
elif ! LD_SHOW_AUXV=1 /bin/true 2>&1; then
    print_unavailable
fi

print_section '/proc/sys/abi/riscv_v_default_allow'
print_optional_file /proc/sys/abi/riscv_v_default_allow

print_section 'device-tree CPU properties'
shopt -s nullglob
cpu_directories=(/proc/device-tree/cpus/cpu@*)
shopt -u nullglob

if [[ "${#cpu_directories[@]}" -eq 0 ]]; then
    print_unavailable
else
    device_tree_properties=(
        compatible
        riscv,isa
        riscv,isa-base
        riscv,isa-extensions
        riscv,vlenb
    )

    for cpu_directory in "${cpu_directories[@]}"; do
        printf -- '-- %s --\n' "$cpu_directory"

        for property in "${device_tree_properties[@]}"; do
            print_device_tree_property "$cpu_directory/$property"
        done
    done
fi
