# Parch Linux VM Images

This repository builds monthly Parch Linux virtual-machine disk images. These
are preinstalled VM disks, not installer ISOs.

## Image profiles

Both profiles use the package foundation in `packages.txt` and the Parch core
layer in `profiles/core/packages.txt`.

| Profile | Description | Additional packages |
| --- | --- | --- |
| `core` | GUI-less Parch system for terminal and VM workloads | Parch core layer only |
| `plasma` | Graphical Parch desktop with SDDM | Everything in `profiles/plasma/packages.txt` |

Every image supports both legacy BIOS and UEFI. One GPT disk contains a BIOS
boot partition, an EFI System Partition, and the root filesystem, so the same
raw or qcow2 image works with either firmware.

## Default login

Cloud-init is optional. Images can be used directly with:

| Setting | Value |
| --- | --- |
| Username | `parch` |
| Password | `parch` |
| Hostname | `parch-vm` |
| Root login | Locked |

The `parch` user belongs to `wheel` and has normal password-authenticated
`sudo` access. Change the published password after the first login:

```bash
passwd
```

SSH password authentication is disabled because the image credentials are
public. Use the VM console or Plasma login screen, or provide an SSH key using
cloud-init. Supported cloud-init data sources are NoCloud, ConfigDrive, and
OpenStack.

## Build locally

Builds require an Arch-based x86_64 host and root privileges:

```bash
sudo pacman -S --needed \
  arch-install-scripts \
  dosfstools \
  e2fsprogs \
  gptfdisk \
  qemu-img

git submodule update --init --recursive
sudo ./build.sh --profile core
sudo ./build.sh --profile plasma
```

The default output is a 16 GiB sparse qcow2 disk:

```text
output/parch-core.qcow2
output/parch-plasma.qcow2
```

Available build options:

```text
--profile core|plasma
--size SIZE
--format raw|qcow2
--output PATH
```

For example:

```bash
sudo ./build.sh --profile plasma --size 24G --format raw
```

## Test images

Static repository validation:

```bash
./test/validate.sh
```

The boot smoke test starts an existing image with both SeaBIOS and OVMF and
waits for the serial login prompt. Install its additional dependencies first:

```bash
sudo pacman -S --needed edk2-ovmf qemu-system-x86
./test/boot-smoke.sh output/parch-core.qcow2
```

The test accepts both qcow2 and raw images.

## Automation

GitHub Actions validates the repository, builds both profiles in an Arch Linux
container, and tests each image with legacy BIOS and UEFI. Builds are uploaded
as compressed workflow artifacts.

On the scheduled run at 03:17 UTC on the first day of each month, the workflow
publishes:

```text
parch-core-YYYY.MM.qcow2.zst
parch-plasma-YYYY.MM.qcow2.zst
```

Each compressed image is accompanied by a `.sha256` checksum file.

Manual workflow runs also publish or update the release for the current month.
