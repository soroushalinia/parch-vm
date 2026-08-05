#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
readonly OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
readonly CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/cache}"
readonly OVERLAY_DIR="$ROOT_DIR/overlays/overlays/base-config"
readonly PACMAN_CONFIG="$ROOT_DIR/pacman.conf"

profile="core"
image_size="16G"
output_format="qcow2"
output_path=""
mount_dir=""
raw_image=""
loop_devices=()

usage() {
    cat <<'EOF'
Build a bootable Parch Linux VM disk image.

Usage: sudo ./build.sh [options]

Options:
  --profile core|plasma  Image profile (default: core)
  --size SIZE            Raw disk size accepted by truncate (default: 16G)
  --format raw|qcow2     Output format (default: qcow2)
  --output PATH          Output file path
  -h, --help             Show this help

Environment:
  WORK_DIR               Temporary build directory (default: ./work)
  OUTPUT_DIR             Image output directory (default: ./output)
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    if [[ -n "$mount_dir" ]]; then
        umount -R "$mount_dir" 2>/dev/null || true
    fi
    for dev in "${loop_devices[@]}"; do
        losetup -d "$dev" 2>/dev/null || true
    done
}
trap cleanup EXIT

while (($#)); do
    case "$1" in
        --profile)
            (($# >= 2)) || die "--profile requires a value"
            profile="$2"
            shift 2
            ;;
        --size)
            (($# >= 2)) || die "--size requires a value"
            image_size="$2"
            shift 2
            ;;
        --format)
            (($# >= 2)) || die "--format requires a value"
            output_format="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || die "--output requires a value"
            output_path="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ "$profile" == "core" || "$profile" == "plasma" ]] ||
    die "profile must be 'core' or 'plasma'"
[[ "$output_format" == "raw" || "$output_format" == "qcow2" ]] ||
    die "format must be 'raw' or 'qcow2'"
[[ $EUID -eq 0 ]] || die "the image build must run as root"
[[ -f "$PACMAN_CONFIG" ]] || die "missing pacman.conf"
[[ -d "$OVERLAY_DIR/etc" ]] ||
    die "base-config submodule is missing; run: git submodule update --init --recursive"

required_commands=(
    arch-chroot
    install
    losetup
    mkfs.ext4
    mkfs.fat
    mount
    mountpoint
    pacstrap
    sgdisk
    truncate
    umount
)
[[ "$output_format" == "raw" ]] || required_commands+=(qemu-img)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null ||
        die "missing required command: $command_name"
done

if [[ -z "$output_path" ]]; then
    output_path="$OUTPUT_DIR/parch-${profile}.${output_format}"
fi
mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$(dirname -- "$output_path")"

build_id="$(date -u +%Y%m%d%H%M%S)-$$"
mount_dir="$WORK_DIR/mnt-$build_id"
raw_image="$WORK_DIR/parch-${profile}-$build_id.raw"
mkdir -p "$mount_dir"

package_files=(
    "$ROOT_DIR/packages.txt"
    "$ROOT_DIR/profiles/core/packages.txt"
)
if [[ "$profile" == "plasma" ]]; then
    package_files+=("$ROOT_DIR/profiles/plasma/packages.txt")
fi
mapfile -t packages < <(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${package_files[@]}" |
        awk '!seen[$0]++'
)

printf 'Building Parch Linux profile=%s size=%s format=%s\n' \
    "$profile" "$image_size" "$output_format"

truncate -s "$image_size" "$raw_image"
sgdisk --zap-all "$raw_image"
sgdisk --new=1:1MiB:+1MiB --typecode=1:ef02 --change-name=1:PARCH_BIOS "$raw_image"
sgdisk --new=2:0:+512MiB --typecode=2:ef00 --change-name=2:PARCH_EFI "$raw_image"
sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:PARCH_ROOT "$raw_image"

loop_device="$(losetup --find --show "$raw_image")"
loop_devices+=("$loop_device")

p2_sector=$(sgdisk -i 2 "$raw_image" | awk '/^Partition size/ {print $3}')
p2_start=$(sgdisk -i 2 "$raw_image" | awk '/^First sector/ {print $3}')
loop_p2=$(losetup --find --show \
    -o $((p2_start * 512)) \
    --sizelimit $((p2_sector * 512)) \
    "$raw_image")
loop_devices+=("$loop_p2")

p3_sector=$(sgdisk -i 3 "$raw_image" | awk '/^Partition size/ {print $3}')
p3_start=$(sgdisk -i 3 "$raw_image" | awk '/^First sector/ {print $3}')
loop_p3=$(losetup --find --show \
    -o $((p3_start * 512)) \
    --sizelimit $((p3_sector * 512)) \
    "$raw_image")
loop_devices+=("$loop_p3")

mkfs.fat -F 32 -n PARCH_EFI "$loop_p2"
mkfs.ext4 -F -L PARCH_ROOT "$loop_p3"

mount "$loop_p3" "$mount_dir"
mkdir -p "$mount_dir/boot"
mount "$loop_p2" "$mount_dir/boot"

mkdir -p "$CACHE_DIR"
pacstrap -C "$PACMAN_CONFIG" -c "$CACHE_DIR" -K "$mount_dir" "${packages[@]}"

local_pkgs=(
    "$ROOT_DIR/pkgs/paru-"*.pkg.tar.zst
    "$ROOT_DIR/pkgs/parch-plymouth-"*.pkg.tar.zst
)
if [[ "$profile" == "plasma" ]]; then
    local_pkgs+=("$ROOT_DIR/pkgs/parch-dorood-"*.pkg.tar.zst)
    local_pkgs+=("$ROOT_DIR/pkgs/ttf-vazirmatn-"*.pkg.tar.zst)
fi
mkdir -p "$mount_dir/root/pkgs"
cp "${local_pkgs[@]}" "$mount_dir/root/pkgs/"

cp -a "$OVERLAY_DIR/etc/." "$mount_dir/etc/"
install -Dm644 "$PACMAN_CONFIG" "$mount_dir/etc/pacman.conf"
install -Dm644 "$ROOT_DIR/config/cloud.cfg.d/90-parch.cfg" \
    "$mount_dir/etc/cloud/cloud.cfg.d/90-parch.cfg"
install -Dm644 "$ROOT_DIR/config/serial-getty.conf" \
    "$mount_dir/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf"

cat >"$mount_dir/etc/fstab" <<'EOF'
LABEL=PARCH_ROOT /     ext4 defaults,noatime 0 1
LABEL=PARCH_EFI  /boot vfat defaults,umask=0077 0 2
EOF

cat >"$mount_dir/etc/os-release" <<'EOF'
NAME="Parch Linux"
PRETTY_NAME="Parch Linux"
ID=parch
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;71;174;255"
HOME_URL="https://parchlinux.com/"
SUPPORT_URL="https://github.com/parchlinux"
BUG_REPORT_URL="https://github.com/parchlinux"
EOF
printf 'Parch Linux \\r (\\l)\n' >"$mount_dir/etc/issue"
printf 'parch-vm\n' >"$mount_dir/etc/hostname"
cat >"$mount_dir/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
127.0.1.1 parch-vm.localdomain parch-vm
EOF

arch-chroot "$mount_dir" /bin/bash -s -- "$profile" "$loop_device" <<'CHROOT'
set -Eeuo pipefail
profile="$1"
disk_device="$2"

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' >/etc/locale.conf
printf 'KEYMAP=us\n' >/etc/vconsole.conf

# Regenerate identity on first boot and create direct console credentials.
: >/etc/machine-id
rm -f /var/lib/dbus/machine-id
passwd --lock root
if ! id parch >/dev/null 2>&1; then
    useradd --create-home --groups wheel --shell /bin/bash parch
fi
printf 'parch:parch\n' | chpasswd
install -Dm440 /dev/stdin /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

# Install embedded packages (paru + Parch-specific).
pacman -U --noconfirm /root/pkgs/*.pkg.tar.zst
rm -rf /root/pkgs

# The build host may not use VirtIO, but the resulting VM image must.
sed -i \
    's/^MODULES=.*/MODULES=(virtio_pci virtio_blk virtio_scsi virtio_net)/' \
    /etc/mkinitcpio.conf
if ! grep -Eq '^HOOKS=.*\bplymouth\b' /etc/mkinitcpio.conf; then
    sed -E -i '/^HOOKS=/ s/(udev|systemd)/\1 plymouth/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

systemctl enable NetworkManager.service
systemctl enable sshd.service
systemctl enable qemu-guest-agent.service
systemctl enable cloud-init-main.service
systemctl enable cloud-config.service
systemctl enable cloud-final.service
systemctl enable serial-getty@ttyS0.service

if [[ "$profile" == "plasma" ]]; then
    systemctl enable sddm.service
    systemctl set-default graphical.target
else
    systemctl set-default multi-user.target
fi

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=Parch \
    --removable \
    --no-nvram
grub-install \
    --target=i386-pc \
    --recheck \
    "$disk_device"
sed -i \
    -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' \
    -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash console=tty0 console=ttyS0,115200n8"/' \
    /etc/default/grub
printf '%s\n' \
    'GRUB_TERMINAL="serial"' \
    'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' \
    >>/etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

# Add world repo as last entry so it's available on the running system
# without blocking the build if the mirror is unreachable.
cat >>/etc/pacman.conf <<'EOF'

[world]
Server = https://mirror.parchlinux.ir/$repo/$arch/
SigLevel = Never
EOF
CHROOT

sync
umount -R "$mount_dir" 2>/dev/null || {
    sleep 1
    umount -R "$mount_dir" 2>/dev/null || true
}
for dev in "${loop_devices[@]}"; do
    losetup -d "$dev"
done
loop_devices=()

rm -f "$output_path"
if [[ "$output_format" == "qcow2" ]]; then
    qemu-img convert -f raw -O qcow2 -c "$raw_image" "$output_path"
else
    mv "$raw_image" "$output_path"
fi
rm -f "$raw_image"

printf 'Image written to %s\n' "$output_path"
if command -v qemu-img >/dev/null; then
    qemu-img info "$output_path"
fi
