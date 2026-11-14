# NanoPC-T4 U-Boot 2026.10 — HDMI + NVMe

U-Boot `2026.10-00006-g333a0521a09e` for the FriendlyElec NanoPC-T4 (RK3399),
upgraded from the previous `v2026.07` base.

All six patches were rebased onto U-Boot `v2026.10` and apply cleanly:

1. `phy-rockchip-pcie`: correct PLL poll timeout, program NPLL 800 MHz / 8
   for the 100 MHz reference, settle delay.
2. `pcie_rockchip`: 100 ms wait after link training.
3. `rk3399-nanopc-t4` U-Boot DT: enable PCIe root complex and PHY.
4. Boot order: SD (`mmc1`) first, then NVMe; eMMC is not an OS target.
5. Config: PCIe/NVMe/PCI init, 115200 baud, full-speed fan via PWM1 preboot,
   `PCLK_RKPWM_PMU` gate.
6. RK3399 clock: accept `ACLK_VOP0`/`HCLK_VOP0` so `vopb` probes and HDMI
   works (`device_probe()` aborts on unsupported assigned clocks).

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

Serial console: **115200 8N1**, 4-pin debug header.

Maskrom recovery: `rkdeveloptool db loader/rk3399_miniloader_v1.26.bin`,
`wl 0x40 idbloader.img`, `wl 0x4000 u-boot.itb`, `rd`.
