#!/bin/sh
#
# Install mainline U-Boot for the FriendlyElec NanoPC-T4 (RK3399) into eMMC.
#
# Layout written (same as every Rockchip RK3399 boot medium):
#   sector 64   (0x8000)  idbloader.img   (TPL/DDR init + SPL)
#   sector 16384 (0x800000) u-boot.itb    (U-Boot proper + FDT + BL31)
#
# The partition table and the OS partitions are left untouched.
#
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IDB="$SCRIPT_DIR/idbloader.img"
ITB="$SCRIPT_DIR/u-boot.itb"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ -f "$IDB" ] || die "missing $IDB"
[ -f "$ITB" ] || die "missing $ITB"
[ $(( $(stat -c %s "$IDB") % 512 )) -eq 0 ] || die "$IDB is not 512-byte aligned"
[ $(( $(stat -c %s "$ITB") % 512 )) -eq 0 ] || die "$ITB is not 512-byte aligned"

# Auto-detect the eMMC: mmcblk devices whose MMC type is "MMC" (not "SD").
TARGET=${1:-}
if [ -z "$TARGET" ]; then
	for sysblk in /sys/block/mmcblk*; do
		[ -e "$sysblk" ] || continue
		name=${sysblk##*/}
		case "$name" in
		mmcblk[0-9] | mmcblk[0-9][0-9]) ;;
		*) continue ;;
		esac
		if [ -r "$sysblk/device/type" ] &&
		   [ "$(cat "$sysblk/device/type")" = "MMC" ]; then
			TARGET="/dev/$name"
			break
		fi
		# eMMC exposes boot0/boot1; SD cards do not.
		if [ -e "$sysblk/boot0" ]; then
			TARGET="/dev/$name"
			break
		fi
	done
fi

[ -n "$TARGET" ] || die "no eMMC found; pass the device explicitly: $0 /dev/mmcblk0"
[ -b "$TARGET" ] || die "$TARGET is not a block device"

# Refuse to write to the device the running system lives on.
root_src=$(findmnt -n -o SOURCE / 2>/dev/null ||
	awk '$2 == "/" { print $1; exit }' /proc/mounts)
case "$root_src" in
"$TARGET" | "$TARGET"p*)
	die "the root filesystem is on $TARGET; boot from SD and retry"
	;;
esac

sysfs=/sys/block/${TARGET##*/}
if [ -r "$sysfs/device/type" ] && [ "$(cat "$sysfs/device/type")" != "MMC" ]; then
	echo "WARNING: $TARGET reports type '$(cat "$sysfs/device/type")', not eMMC" >&2
fi

for p in "$TARGET"p*; do
	[ -b "$p" ] || continue
	if grep -q "^$p " /proc/mounts; then
		die "$p is mounted; unmount it first"
	fi
done

size=$(blockdev --getsize64 "$TARGET")
[ "$size" -ge $((16 * 1024 * 1024)) ] || die "$TARGET is too small to be the eMMC"

echo "Target eMMC : $TARGET"
echo "Size        : $size bytes"
echo "idbloader   : $IDB"
echo "U-Boot FIT  : $ITB"
printf 'Overwrite the U-Boot area on %s? [y/N] ' "$TARGET"
read -r answer
case "$answer" in
y | Y | yes | YES) ;;
*) echo "Aborted."; exit 1 ;;
esac

# Make sure nothing on the target is mounted, then write both stages.
for p in "$TARGET"p*; do
	[ -b "$p" ] && umount "$p" 2>/dev/null || true
done

dd if="$IDB" of="$TARGET" bs=512 seek=64 conv=notrunc,fsync
dd if="$ITB" of="$TARGET" bs=512 seek=16384 conv=notrunc,fsync

# Clear any environment left by the vendor U-Boot (CONFIG_ENV_OFFSET=0x3F8000,
# CONFIG_ENV_SIZE=0x8000) so the new default boot_targets is used.
dd if=/dev/zero of="$TARGET" bs=512 seek=8128 count=64 conv=notrunc,fsync
sync

idb_blocks=$(( $(stat -c %s "$IDB") / 512 ))
itb_blocks=$(( $(stat -c %s "$ITB") / 512 ))
dd if="$TARGET" bs=512 skip=64 count="$idb_blocks" iflag=fullblock 2>/dev/null |
	cmp -s - "$IDB" || die "idbloader read-back verification failed"
dd if="$TARGET" bs=512 skip=16384 count="$itb_blocks" iflag=fullblock 2>/dev/null |
	cmp -s - "$ITB" || die "U-Boot FIT read-back verification failed"

echo
echo "OK: U-Boot installed on $TARGET."
echo "Power off, remove the SD card (or leave one without a bootable OS),"
echo "then power on. U-Boot loads from eMMC and boots SD first, NVMe second."
