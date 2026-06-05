#!/usr/bin/env bash

set -Eeuo pipefail

image="${1:?usage: boot-smoke.sh IMAGE}"
timeout_seconds="${BOOT_TIMEOUT:-180}"
temporary_files=()
trap 'rm -f "${temporary_files[@]}"' EXIT

command -v qemu-system-x86_64 >/dev/null
command -v qemu-img >/dev/null
[[ -f "$image" ]] || {
    printf 'Image not found: %s\n' "$image" >&2
    exit 1
}

image_format="$(
    qemu-img info --force-share "$image" |
        awk -F': ' '/^file format:/ { print $2; exit }'
)"
[[ -n "$image_format" ]] || {
    printf 'Unable to detect image format: %s\n' "$image" >&2
    exit 1
}

firmware=""
vars_template=""
while IFS=: read -r code vars; do
    if [[ -f "$code" && -f "$vars" ]]; then
        firmware="$code"
        vars_template="$vars"
        break
    fi
done <<'EOF'
/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd
/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd
/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd
EOF
[[ -n "$firmware" ]] || {
    printf 'Unable to find OVMF firmware.\n' >&2
    exit 1
}

run_boot_test() {
    local mode="$1"
    local log_file overlay vars_file qemu_status
    local -a firmware_args=()

    log_file="$(mktemp)"
    overlay="$(mktemp --suffix=.qcow2)"
    temporary_files+=("$log_file" "$overlay")
    qemu-img create -q -f qcow2 -F "$image_format" \
        -b "$(realpath "$image")" "$overlay"

    if [[ "$mode" == "uefi" ]]; then
        vars_file="$(mktemp --suffix=.fd)"
        temporary_files+=("$vars_file")
        cp "$vars_template" "$vars_file"
        firmware_args=(
            -drive "if=pflash,format=raw,readonly=on,file=$firmware"
            -drive "if=pflash,format=raw,file=$vars_file"
        )
    fi

    set +e
    timeout "$timeout_seconds" qemu-system-x86_64 \
        -machine q35,accel=tcg \
        -m 2048 \
        -smp 2 \
        -nodefaults \
        -no-reboot \
        -nographic \
        -serial "file:$log_file" \
        "${firmware_args[@]}" \
        -drive "if=virtio,format=qcow2,file=$overlay" \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0
    qemu_status=$?
    set -e

    if grep -Eq 'parch-vm login:' "$log_file"; then
        printf '%s boot smoke test passed.\n' "${mode^^}"
        return
    fi

    cat "$log_file" >&2
    printf '%s VM did not reach the Parch Linux console (qemu status %s).\n' \
        "${mode^^}" "$qemu_status" >&2
    return 1
}

run_boot_test bios
run_boot_test uefi
