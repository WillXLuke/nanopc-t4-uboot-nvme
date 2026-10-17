#!/bin/bash
#
# Build mainline U-Boot for the FriendlyElec NanoPC-T4 (RK3399) with
# SD -> NVMe boot order and working PCIe/NVMe.
#
# Prereqs: git, make, bison, flex, python3, swig, dtc, aarch64-linux-gnu-*
# BL31:    bl31/rk3399_bl31_v1.35.elf (included) or any TF-A bl31.elf
#          built for PLAT=rk3399.
#
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
UBOOT_SRC=${UBOOT_SRC:-$HERE/uboot}
UBOOT_TAG=${UBOOT_TAG:-v2026.07}
BL31=${BL31:-$HERE/bl31/rk3399_bl31_v1.35.elf}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
OUT=${OUT:-$HERE}

if [ ! -e "$UBOOT_SRC/.git" ]; then
	git clone --depth 1 -b "$UBOOT_TAG" \
		https://github.com/u-boot/u-boot.git "$UBOOT_SRC"
fi

cd "$UBOOT_SRC"

for p in "$HERE"/patches/*.patch; do
	if git apply --check "$p" 2>/dev/null; then
		git apply "$p"
	elif git apply --reverse --check "$p" 2>/dev/null; then
		echo "already applied: ${p##*/}"
	else
		echo "ERROR: patch does not apply: $p" >&2
		exit 1
	fi
done

if [ ! -f "$BL31" ]; then
	echo "ERROR: BL31 not found: $BL31" >&2
	echo "The repository includes bl31/rk3399_bl31_v1.35.elf." >&2
	echo "Alternatively fetch rkbin or build TF-A with 'make PLAT=rk3399 bl31'." >&2
	exit 1
fi

make nanopc-t4-rk3399_defconfig
make -j"$(nproc)" CROSS_COMPILE="$CROSS_COMPILE" BL31="$BL31"

mkdir -p "$OUT"
cp -f idbloader.img u-boot.itb u-boot-rockchip.bin u-boot.dtb "$OUT"/
echo
echo "Built with BL31: $BL31"
echo "Artifacts in:  $OUT"
sha256sum "$OUT"/idbloader.img "$OUT"/u-boot.itb
