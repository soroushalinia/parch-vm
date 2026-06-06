#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'validation error: %s\n' "$*" >&2
    exit 1
}

has_package() {
    local package="$1"
    local manifest="$2"
    grep -qx "$package" "$manifest" ||
        fail "$package is missing from ${manifest#"$ROOT_DIR/"}"
}

readme_mentions_profile() {
    local profile="$1"
    grep -q "profiles/$profile/packages.txt" "$ROOT_DIR/README.md" ||
        fail "README does not mention profiles/$profile/packages.txt"
}

bash -n "$ROOT_DIR/build.sh"
bash -n "$ROOT_DIR/test/boot-smoke.sh"

for profile in core plasma; do
    [[ -f "$ROOT_DIR/profiles/$profile/packages.txt" ]] ||
        fail "missing $profile package manifest"
done

[[ -f "$ROOT_DIR/pacman.conf" ]] || fail "missing pacman.conf"
[[ -d "$ROOT_DIR/overlays/overlays/base-config/etc" ]] ||
    fail "base-config submodule is not initialized"

core_manifest="$ROOT_DIR/profiles/core/packages.txt"
plasma_manifest="$ROOT_DIR/profiles/plasma/packages.txt"

for package in \
    networkmanager \
    bash-completion; do
    has_package "$package" "$core_manifest"
done

for package in \
    sddm \
    plasma \
    elisa \
    okular \
    kalk \
    spectacle \
    kamoso \
    kweather \
    merkuro \
    kdeconnect \
    marknote \
    partitionmanager \
    power-profiles-daemon \
    fastfetch \
    konsole \
    kate \
    dolphin \
    dolphin-plugins \
    xdg-user-dirs \
    ark \
    unzip \
    unrar \
    ttf-vazirmatn \
    android-file-transfer \
    gvfs-mtp; do
    has_package "$package" "$plasma_manifest"
done

for pkg in \
    pkgs/paru-*.pkg.tar.zst \
    pkgs/parch-plymouth-*.pkg.tar.zst \
    pkgs/parch-dorood-*.pkg.tar.zst \
    pkgs/ttf-vazirmatn-*.pkg.tar.zst; do
    [[ -f "$ROOT_DIR/$pkg" ]] ||
        fail "missing embedded package: $pkg"
done

readme_mentions_profile core
readme_mentions_profile plasma

duplicate_packages="$(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        "$ROOT_DIR/packages.txt" "$core_manifest" "$plasma_manifest" |
        sort |
        uniq -d
)"
[[ -z "$duplicate_packages" ]] ||
    fail "packages are duplicated across manifests: $duplicate_packages"

grep -q 'package_files+=.*profiles/plasma' "$ROOT_DIR/build.sh" ||
    fail "plasma profile does not inherit the core package layer"
grep -q 'typecode=1:ef02' "$ROOT_DIR/build.sh" ||
    fail "BIOS boot partition is not configured"
grep -q -- '--target=i386-pc' "$ROOT_DIR/build.sh" ||
    fail "BIOS GRUB target is not installed"
grep -q -- '--target=x86_64-efi' "$ROOT_DIR/build.sh" ||
    fail "UEFI GRUB target is not installed"
grep -q "printf 'parch:parch" "$ROOT_DIR/build.sh" ||
    fail "default parch credentials are not configured"
grep -q 'passwd --lock root' "$ROOT_DIR/build.sh" ||
    fail "root account is not locked"
grep -q '%wheel ALL=(ALL:ALL) ALL' "$ROOT_DIR/build.sh" ||
    fail "password-authenticated sudo policy is not configured"
grep -q 'name: parch' "$ROOT_DIR/config/cloud.cfg.d/90-parch.cfg" ||
    fail "cloud-init default user does not match the image user"
grep -q '| Username | `parch` |' "$ROOT_DIR/README.md" ||
    fail "README default login is out of date"

printf 'Repository validation passed.\n'
