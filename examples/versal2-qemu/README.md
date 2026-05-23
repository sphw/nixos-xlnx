# versal2-qemu example

Minimal `nixosConfiguration` that boots Versal AI Edge Gen 2 under
QEMU. Three entry points (upstream, downstream, multiarch) all
consume the same NixOS configuration; pick the one whose machine
model matches your needs.

## What this gives you

A `qemu-versal2` config with:

- `hardware.xlnx.platform = "versal2"`, `xlnxVersion = "2025.1"`
- `nixosModules.versal2-sd-image` — 4 KiB-sector disk image with an
  EFI System Partition holding systemd-boot + kernel + initrd. The
  *same* disk image works on real UFS hardware.
- `hardware.xlnx.bootBin.enable = false` — QEMU loads the bootloader
  chain (BL31, U-Boot) via `-device loader`, so no `BOOT.BIN` is
  packaged. Drop this line for real hardware.
- Root login via password `nixos`, SSH enabled

## Run it

### Upstream QEMU (`amd-versal2-virt`)

Uses system `qemu-system-aarch64` (must be ≥ 10.2).

```bash
nix run .#qemu-versal2-upstream
```

Smaller dependency footprint, but as of QEMU 10.2.x the machine
model is incomplete — BL31 starts but UART output may not appear.

### Downstream QEMU fork (`arm-generic-fdt`)

Builds AMD's downstream QEMU fork (`Xilinx/qemu`, based on 8.2.7)
plus the matching hardware-DTB collection. First build downloads
and compiles QEMU from source.

```bash
nix run .#qemu-versal2-downstream
```

### Multiarch wrapper (`qemu-system-amd-fpga-multiarch`)

Drives the full PMC + ASU + APU chain from a real `BOOT.BIN`. Needs
the AMD VEK385 QEMU prebuilt for the BOOT.BIN, OSPI image, and the
multiarch hardware DTBs:

```bash
nix run .#qemu-versal2-multiarch -- --prebuilt-dir ~/vek385-prebuilt
```

The NixOS disk image (built from this flake) is mounted as the SCSI
target; U-Boot's EFI BootMgr discovers the ESP and chainloads
systemd-boot → NixOS.

Exit QEMU with `Ctrl-A x` in any case.

## Use it as a starting point for a real board

Once you have a Vivado-exported XSA for your custom board:

1. Run `scripts/gendt.tcl your.xsa ./out/ -platform versal2`.
2. Copy this `flake.nix`, add `bitstream`, `sdtDir`, `dtDir` pointing
   at your `./out/...` paths.
3. Remove `hardware.xlnx.bootBin.enable = false;` — real silicon
   needs a packaged `BOOT.BIN`.
4. Build the disk image: `nix build .#sdImage`. The result is the
   same 4 KiB-sector / ESP layout used by the QEMU paths, so it
   flashes to UFS unchanged.
