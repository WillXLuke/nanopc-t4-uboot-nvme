# U-Boot for FriendlyElec NanoPC-T4 (RK3399): SD → NVMe boot

Mainline U-Boot **v2026.07** built for the NanoPC-T4, with:

* working RK3399 PCIe root complex and PCIe PHY (so NVMe is usable in U-Boot),
* default boot order **SD card first, NVMe second** (eMMC is not a boot target),
* onboard **fan at full speed during boot** (PWM1, 100% duty),
* U-Boot installed in **eMMC** (TPL/SPL + U-Boot proper + BL31), so the board
  boots without any SD card and then finds the OS on SD or NVMe.

Prebuilt artifacts are in this directory; the source changes are in
`patches/` and can be rebuilt with `./build-uboot.sh`.

## Files

| File | Purpose |
| --- | --- |
| `idbloader.img` | TPL (DDR init) + SPL, write at **sector 64** |
| `u-boot.itb` | U-Boot proper + control FDT + BL31, write at **sector 16384** |
| `u-boot-rockchip.bin` | Both stages in one image, write at **sector 64** (alternative) |
| `u-boot.dtb` | U-Boot control device tree (inspection/debug) |
| `install-uboot-emmc.sh` | Safe eMMC installer (auto-detects the eMMC, verifies the write) |
| `SHA256SUMS` | Checksums of the images above |
| `bl31/rk3399_bl31_v1.35.elf` | BL31 used by the build (FriendlyElec rkbin) |
| `loader/rk3399_miniloader_v1.26.bin` | Rockchip loader for maskrom flashing |

## Why these patches

### 1. PCIe PHY power-on (`0001`)

Three bugs in the PHY power-on path kept the PLL from locking on RK3399:

* `readl_poll_sleep_timeout()` takes `(sleep_us, timeout_us)`, but all three
  PLL polls passed `(20 * 1000, 50)` — a 20 ms sleep and a 50 µs timeout.
  The loop gave up after a single 20 ms sleep instead of polling for the
  intended 100 ms. It now uses `(200, 100 * 1000)`, matching the current
  Linux driver.
* `SCLK_PCIEPHY_REF` must be muxed to `SCLK_PCIEPHY_REF100M` and run at
  100 MHz; the PHY PLL is hard-coded for a 100 MHz reference. The driver
  applies the `assigned-clock-*` properties (best effort) and forces
  `clk_set_rate(&refclk, 100000000)`.
* The 100 MHz source is **NPLL / 8**, and U-Boot's static RK3399 clock
  driver never configured NPLL or the divider — it only flipped the mux
  bit, so `clk_get_rate()` reported 100 MHz while the PHY actually had no
  clock. `rk3399_pciephy_set_clk()` now programs NPLL to 800 MHz, sets the
  `clksel_con[18]` /8 divider and selects the 100 MHz parent.

Before the fix the boot log showed `pll lock timeout!` and
`failed to power on phy`, and no NVMe device was enumerated.

### 2. Settle delay after link training (`0002`)

Several NVMe SSDs abort the first config-space read if it happens immediately
after the link comes up. A 100 ms `mdelay()` after link-up (before the PCI
scan) makes the device enumerate reliably. This is the RK3399 issue reported
by Kurt Miller on the U-Boot list ("Add delay after link-training").

### 3. NanoPC-T4 device tree (`0003`)

`pcie0` and `pcie_phy` are explicitly enabled in
`arch/arm/dts/rk3399-nanopc-t4-u-boot.dtsi`. The upstream nanopi4 DT already
describes the M.2 slot correctly:

* `num-lanes = <4>`, `max-link-speed = <1>` (U-Boot trains Gen1),
* `ep-gpios = <&gpio2 RK_PA4 GPIO_ACTIVE_HIGH>` = PERST#,
* `vpcie3v3-supply`, `vpcie1v8-supply`, `vpcie0v9-supply`,
* `assigned-clock-parents = <&cru SCLK_PCIEPHY_REF100M>`.

### 4. Boot order (`0004`)

`BOOT_TARGETS` in `include/configs/evb_rk3399.h` (the NanoPC-T4 target) is now:

```
mmc1 nvme
```

`mmc1` is the microSD slot (`sdmmc@fe320000`), `mmc0` is eMMC
(`sdhci@fe330000`). U-Boot itself lives on eMMC; the OS is looked up on SD
first and on NVMe second. U-Boot 2026.07 boots with bootstd
(`bootcmd=bootflow scan -lb`), which uses the `boot_targets` environment
variable as its scan order.

To change it at runtime:

```
setenv boot_targets 'mmc1 nvme'
saveenv
```

### 5. Config and fan (`0005`)

Explicitly enables `CONFIG_PCIE_ROCKCHIP`, `CONFIG_PHY_ROCKCHIP_PCIE`,
`CONFIG_NVME_PCI`, `CONFIG_CMD_NVME` and `CONFIG_PCI_INIT_R`, and sets the
console/debug UART to `CONFIG_BAUDRATE=115200` (instead of 1500000).

It also enables `CONFIG_CMD_PWM`, adds the full-speed fan `preboot` command,
ungates `PCLK_RKPWM_PMU` in the RK3399 PMU clock driver and enables the PWM
clock from the Rockchip PWM probe. See "Fan at full speed during boot" below.

## Install U-Boot into eMMC

### Method A: boot from SD (recommended)

Boot any Linux from SD (the installer must **not** run from the eMMC), copy
this directory to the board, then:

```sh
sudo ./install-uboot-emmc.sh
```

It auto-detects the eMMC (`/sys/block/mmcblk*/device/type` == `MMC`), refuses
to write to the device the system is running from, unmounts its partitions and
verifies both writes by reading them back. It also clears the 32 KiB vendor
U-Boot environment at offset `0x3F8000`, so the built-in
`boot_targets=mmc1 nvme` is used instead of stale vendor settings.

Explicit target (if detection is ambiguous):

```sh
sudo ./install-uboot-emmc.sh /dev/mmcblk0
```

Expected serial output after power-on:

```
U-Boot 2026.07...
Model: FriendlyElec NanoPC-T4
...
PCIE-0: Link up (Bus0)
...
Scanning for bootflows in boot_targets: mmc1, nvme
```

### Method B: maskrom / rkdeveloptool

If the board has no working U-Boot, use Rockchip maskrom mode:

1. Hold the **BOOT** key while powering on (or short the maskrom pads).
2. On the host:

```sh
sudo rkdeveloptool ld
# included loader (Rockchip MiniLoaderAll with DDR init)
sudo rkdeveloptool db loader/rk3399_miniloader_v1.26.bin
sudo rkdeveloptool wl 0x40   idbloader.img
sudo rkdeveloptool wl 0x4000 u-boot.itb
sudo rkdeveloptool rd
```

`wl` takes **sector** numbers: `0x40` = 32 KiB, `0x4000` = 8 MiB.

Do **not** use `rkdeveloptool wl 0 ...` — that would destroy the GPT.

## Verify from the U-Boot prompt

Serial console: **115200 8N1** on the 4-pin debug header (3.3 V USB-TTL).

```
printenv boot_targets        # mmc1 nvme
pci enum
pci list                     # the NVMe controller should appear
nvme scan
nvme info
bootflow scan -lb            # scans SD then NVMe
```

On a good boot the log contains:

```
rockchip_pcie pcie@f8000000: PCIE-0: Link up (Bus0)
```

If `pci list` is empty, check the serial log for:

* `pll lock timeout (refclk N Hz)!` → the PHY PLL did not lock. `N` must be
  `100000000`; if it is `0` or `24000000`, the clock mux/gate is still wrong.
* `PCIe link training gen1 timeout` → PLL locked but no endpoint; check the
  SSD is seated and PERST# (GPIO2_A4) is released.
* `failed to get pcie-phy` → device tree problem.

## Boot files on the NVMe

U-Boot only loads the OS; the NVMe needs a bootable layout that bootstd
understands. Any of these work:

* `/boot/extlinux/extlinux.conf` on an ext4/FAT partition (with `kernel`,
  `fdt`/`fdtdir`, `append root=...`),
* an EFI system partition with `EFI/BOOT/BOOTAA64.EFI`,
* a `boot.scr` produced by `mkimage -T script`.

The mainline DT (`rockchip/rk3399-nanopc-t4.dtb`) is selected by
`fdtfile` and is present in the U-Boot environment.

## Fan at full speed during boot

The 12 V fan rail is switched by **PWM1** (`GPIO4_C6`). The default U-Boot
environment contains:

```
preboot=pwm config 1 0 50000 50000; pwm enable 1 0
```

`pwm1` is `/pwm@ff420010`, period 50000 ns (20 kHz) and duty 50000 ns
(100%), so the fan runs at full speed before the boot delay and stays there
until Linux's `pwm-fan` driver takes over the channel.

Change or disable it at runtime with:

```
setenv preboot 'pwm config 1 0 50000 25000; pwm enable 1 0'   # 50%
setenv preboot                                                 # disable
saveenv
```

## Notes

* U-Boot's RK3399 PCIe driver trains **Gen1** only. Linux re-trains the link
  at Gen2 after boot, so NVMe performance under Linux is unaffected.
* The 3.3 V rail of the M.2 slot is always on; PERST# is GPIO2_A4.
* `u-boot-rockchip.bin` is an alternative to the two `dd` writes: it contains
  `idbloader.img` at offset 0 and `u-boot.itb` at offset `0x7f8000`, so writing
  it at sector 64 places the FIT at 8 MiB. The installer uses the two-stage
  form because the offsets are explicit and easy to verify.
* eMMC env is stored at `0x3F8000` (inside the reserved loader1 area); a
  `saveenv` only writes that small sector.

## Rebuild

```sh
./build-uboot.sh
```

The script clones U-Boot `v2026.07`, applies `patches/0001..0005`, builds with
`CROSS_COMPILE=aarch64-linux-gnu-` and copies the artifacts to the repository
root.

BL31: the build uses the included `bl31/rk3399_bl31_v1.35.elf` from
<https://github.com/friendlyarm/rkbin> (branch `friendlyelec`). A TF-A
`bl31.elf` built with `make PLAT=rk3399 bl31` also works; the rkbin release is
used here because building TF-A for RK3399 also needs `arm-none-eabi-gcc` for
the Cortex-M0 firmware.

## References

1. FriendlyElec NanoPC-T4 wiki (board, eMMC/GPT layout, U-Boot build):
   <https://wiki.friendlyelec.com/wiki/index.php/NanoPC-T4>
2. U-Boot Rockchip board documentation (idbloader at 64, U-Boot at 16384):
   <https://github.com/u-boot/u-boot/blob/master/doc/board/rockchip/rockchip.rst>
3. U-Boot RK3399 PCIe host driver:
   <https://github.com/u-boot/u-boot/commit/99d59069c0a18147b1a475236b0632d085315c43>
4. U-Boot Rockchip PCIe PHY driver:
   <https://github.com/u-boot/u-boot/commit/89f2fa0b5e82fa5fa05e5bce0e24bc1d863270ce>
5. U-Boot switch of the PCIe driver to generic PHY (background on the PHY
   binding): <https://github.com/u-boot/u-boot/commit/ce920e0e56eaeb2442eb27b87d0750cbd1e5bf15>
6. Armbian forum, "mainline u-boot (March 2024) rk3399 nvme boot" — the
   missing PCIe PHY clock patch:
   <https://forum.armbian.com/topic/35938-mainline-u-boot-march-2024-rk3399-nvme-boot/>
7. Armbian forum, "Can the mainline uboot now boot the nanopc-t4 from nvme?":
   <https://forum.armbian.com/topic/21309-can-the-mainline-uboot-now-boot-the-nanopc-t4%EF%BC%88rk3399%EF%BC%89-from-the-nvme/>
8. Manjaro forum, NVMe/U-Boot on RK3399 and the generic-PHY regression report:
   <https://forum.manjaro.org/t/it-seems-that-nvme-and-btrfs-enabled-u-boot-should-be-ported-for-rk3399-devices/112620>
9. U-Boot list, "[PATCH] rockchip: Add delay after link-training":
   <https://lists.denx.de/pipermail/u-boot/2020-June/414478.html>
10. Linux patch, "arm64: dts: rockchip: Improve nanopi4 PCIe" (supplies, lanes):
    <https://github.com/xanmod/linux/commit/876816b2679f0bf2bdc5f9d04b00f58f419d88e2>
11. FriendlyElec rkbin (BL31 v1.35 used here):
    <https://github.com/friendlyarm/rkbin>
12. FriendlyElec U-Boot tree (vendor layout reference):
    <https://github.com/friendlyarm/uboot-rockchip>
13. Rockchip RK3399 PCIe developer guide:
    <https://build.khadas.com/khadas/test/edge2/RKDocs/common/PCie/Rockchip_RK3399_Developer_Guide_PCIe_CN.pdf>
14. U-Boot bootstd documentation (`boot_targets` / `bootdev-order`):
    <https://github.com/u-boot/u-boot/blob/master/doc/develop/bootstd/overview.rst>
