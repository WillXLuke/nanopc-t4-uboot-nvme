# NanoPC-T4 U-Boot 2026.07 — HDMI fix

U-Boot `2026.07-00006-g38adcf93dc26` for the FriendlyElec NanoPC-T4 (RK3399).

## HDMI fix

`vopb` carries `assigned-clocks = <&cru ACLK_VOP0>, <&cru HCLK_VOP0>`.
`device_probe()` applies those through `clk_set_defaults()` and aborts the
probe when a rate cannot be set. The RK3399 clock driver only accepted the
VOP1 variants, so `vopb` never probed and HDMI had no output.

`ACLK_VOP0`/`HCLK_VOP0` are now accepted like VOP1 (reset-default dividers
kept), so VOPB probes and drives the HDMI output. See patch `0006`.

## Also included

- RK3399 PCIe PHY power-on fix: correct PLL poll timeout, program NPLL
  800 MHz / 8 for the 100 MHz reference, settle delay after link training.
- NVMe enabled; default boot order **SD (`mmc1`) first, then NVMe**.
- U-Boot installed in eMMC (idbloader + u-boot.itb with BL31).
- Console/debug UART at **115200 8N1**.
- Onboard fan at **full speed during boot** (PWM1, 100% duty).

## Assets

| File | Purpose |
| --- | --- |
| `idbloader.img` | TPL/SPL, write at sector **64** |
| `u-boot.itb` | U-Boot + FDT + BL31, write at sector **16384** |
| `u-boot-rockchip.bin` | both stages, write at sector **64** (alternative) |
| `u-boot.dtb` | control device tree (inspection) |
| `install-uboot-emmc.sh` | eMMC installer with auto-detect and read-back |
| `SHA256SUMS` | checksums |

## Flash

From SD (not from eMMC):

```sh
sudo ./install-uboot-emmc.sh
```

or manually:

```sh
sudo dd if=idbloader.img of=/dev/mmcblkX bs=512 seek=64    conv=notrunc,fsync
sudo dd if=u-boot.itb    of=/dev/mmcblkX bs=512 seek=16384 conv=notrunc,fsync
```

Verify:

```sh
sha256sum -c SHA256SUMS
```

Maskrom recovery: `rkdeveloptool db loader/rk3399_miniloader_v1.26.bin`,
`wl 0x40 idbloader.img`, `wl 0x4000 u-boot.itb`, `rd`.

Serial console: **115200 8N1**, 4-pin debug header.

After boot, U-Boot should show the console on HDMI; check Linux with
`/sys/class/drm/card0-HDMI-A-1/status` and `dmesg | grep -i hdmi`.
