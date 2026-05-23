{
  pkgs,
  lib,
  nixosCfg,
}:

# Versal2 QEMU runner packages. Each is a `writeShellApplication` whose
# body has every Nix-store path pre-substituted at build time.
#
# Usage from a flake.nix:
#
#   runners = import ../../qemu-versal2-runners.nix {
#     inherit pkgs lib;
#     nixosCfg = nixosCfg;
#   };
#   packages.aarch64-linux = {
#     qemu-versal2-upstream   = runners.upstream;
#     qemu-versal2-downstream = runners.downstream;
#     qemu-versal2-multiarch  = runners.multiarch;
#   };
#
#   nix run .#qemu-versal2-upstream
#   nix run .#qemu-versal2-downstream
#   nix run .#qemu-versal2-multiarch -- --prebuilt-dir ~/vek385-prebuilt

let
  bl31     = pkgs.armTrustedFirmwareVersal2;
  uboot    = pkgs.ubootVersal2;
  kernel   = nixosCfg.config.system.build.kernel;
  initrd   = nixosCfg.config.system.build.initialRamdisk;
  toplevel = nixosCfg.config.system.build.toplevel;

  # The cmdline baked into the sw-dtb at build time, so the DTB
  # rebuilds when kernelParams change.
  bakedBootargs =
    "earlycon console=ttyAMA0,115200n8 root=/dev/ram0 "
    + "init=${toplevel}/init "
    + lib.concatStringsSep " " nixosCfg.config.boot.kernelParams;

  swDtbUpstream = pkgs.versal2-qemu-swdtb.dumpedDtb {
    bootargs = bakedBootargs;
  };
  swDtbDownstream = pkgs.versal2-qemu-swdtb.hwDtb {
    bootargs = bakedBootargs;
  };
in
{
  # Upstream QEMU's `amd-versal2-virt` machine. Requires
  # qemu-system-aarch64 >= 10.2.
  upstream = pkgs.writeShellApplication {
    name = "qemu-versal2-upstream";
    runtimeInputs = [ pkgs.qemu ];
    text = ''
      exec qemu-system-aarch64 \
        -M amd-versal2-virt \
        -m 4G \
        -display none -monitor none \
        -serial stdio \
        -device loader,file=${bl31}/bl31.elf,cpu-num=0 \
        -device loader,file=${uboot}/u-boot.elf \
        -device loader,addr=0x00200000,file=${kernel}/Image \
        -device loader,addr=0x50000000,file=${swDtbUpstream} \
        -device loader,addr=0x10000000,file=${initrd}/initrd \
        -device loader,addr=0xEC200300,data=0x3EE,data-len=4 \
        "$@"
    '';
  };

  # AMD's downstream QEMU fork (`-M arm-generic-fdt`). All artifacts
  # built from Nix; no system qemu required.
  downstream = pkgs.writeShellApplication {
    name = "qemu-versal2-downstream";
    runtimeInputs = [ pkgs.qemu-xlnx ];
    text = ''
      exec qemu-system-aarch64 \
        -M arm-generic-fdt \
        -hw-dtb ${pkgs.qemu-devicetrees-xlnx}/SINGLE_ARCH/board-versal2-psxc-vek385.dtb \
        -m 4G \
        -display none -monitor none \
        -serial null -serial null -serial stdio \
        -device loader,file=${bl31}/bl31.elf,cpu-num=0 \
        -device loader,file=${uboot}/u-boot.elf \
        -device loader,addr=0x00200000,file=${kernel}/Image \
        -device loader,addr=0x10000000,file=${initrd}/initrd \
        -device loader,addr=0x50000000,file=${swDtbDownstream} \
        -device loader,addr=0xEC200300,data=0x3EE,data-len=4 \
        "$@"
    '';
  };

  # AMD's multiarch wrapper. Drives PMC (microblazeel) + ASU
  # (riscv32) + APU (aarch64) sub-QEMUs from a BOOT.BIN. Boots a real
  # PLM/PMC chain, so it needs the AMD-supplied prebuilt directory
  # for BOOT.BIN, OSPI image, and the multiarch hardware DTBs. The
  # NixOS disk image (4 KiB-sector ESP, systemd-boot on FAT) is
  # baked in.
  multiarch = pkgs.writeShellApplication {
    name = "qemu-versal2-multiarch";
    runtimeInputs = with pkgs; [
      qemu-xlnx-multiarch
      zstd
      coreutils
    ];
    text = ''
      usage() {
        cat <<EOF
      Usage: $(basename "$0") --prebuilt-dir DIR

      Boot a Versal AI Edge Gen 2 system end-to-end via AMD's multiarch
      QEMU wrapper. DIR is the unpacked AMD VEK385 QEMU prebuilt;
      provides BOOT.BIN, the OSPI MTD image, and the multiarch
      qemu-hw-devicetrees.
      EOF
        exit "''${1:-0}"
      }

      prebuilt=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --prebuilt-dir) prebuilt="$2"; shift 2 ;;
          --prebuilt-dir=*) prebuilt="''${1#*=}"; shift ;;
          -h|--help) usage 0 ;;
          --) shift; break ;;
          *) break ;;
        esac
      done

      if [ -z "$prebuilt" ]; then
        echo "error: --prebuilt-dir is required" >&2
        usage 1
      fi
      prebuilt=$(cd "$prebuilt" && pwd)

      BOOTBIN="$prebuilt/BOOT-versal-2ve-2vm-vek385-sdt-seg.bin"
      OSPI_SRC="$prebuilt/qemu-ospi-versal-2ve-2vm-vek385-sdt-seg.bin"
      DTB_DIR="$prebuilt/qemu-hw-devicetrees/multiarch"

      for f in \
        "$BOOTBIN" \
        "$OSPI_SRC" \
        "$DTB_DIR/board-versal2-psxc-vek385.dtb" \
        "$DTB_DIR/board-versal2-pmxc-virt.dtb" \
        "$DTB_DIR/board-versal2-asu-virt.dtb"
      do
        if [ ! -f "$f" ]; then
          echo "error: missing $f" >&2
          exit 1
        fi
      done

      # The sdImage derivation places exactly one .img(.zst); compute
      # the exact path at build time so the runtime stays free of shell
      # globbing/file-listing.
      DISK_SRC=${
        let
          sd = nixosCfg.config.system.build.sdImage;
          name = nixosCfg.config.image.baseName + ".img"
            + lib.optionalString nixosCfg.config.sdImage.compressImage ".zst";
        in
        "${sd}/sd-image/${name}"
      }

      TMPDIR_QEMU=$(mktemp -d)
      trap 'rm -rf "$TMPDIR_QEMU"' EXIT

      OSPI="$TMPDIR_QEMU/qemu-ospi.bin"
      cp "$OSPI_SRC" "$OSPI"
      chmod +w "$OSPI"

      DISK="$TMPDIR_QEMU/nixos.img"
      ${
        if nixosCfg.config.sdImage.compressImage then
          ''zstd -d -o "$DISK" "$DISK_SRC" >/dev/null''
        else
          ''cp "$DISK_SRC" "$DISK"''
      }
      chmod +w "$DISK"

      exec qemu-system-amd-fpga-multiarch \
        -machine arm-generic-fdt \
        -m 8G \
        -boot arch=versal2ve2vm -boot mode=8 \
        -kernel "$BOOTBIN" \
        -dtb "$DTB_DIR/board-versal2-psxc-vek385.dtb" \
        -serial null -serial null -serial null -serial mon:stdio \
        -nodefaults \
        -drive "file=$OSPI,if=mtd,format=raw,index=0" \
        -device scsi-hd,drive=d1,bus=scsi.0,channel=0,scsi-id=0,lun=0,logical_block_size=4096,physical_block_size=4096 \
        -drive "file=$DISK,if=none,id=d1,format=raw" \
        -plm-args "-M microblaze-fdt \
                   -device loader,addr=0xf0000000,data=0xba020004,data-len=4 \
                   -device loader,addr=0xf0000004,data=0xb800fffc,data-len=4 \
                   -device loader,addr=0xF1110624,data=0x0,data-len=4 \
                   -device loader,addr=0xF1110620,data=0x1,data-len=4 \
                   -hw-dtb $DTB_DIR/board-versal2-pmxc-virt.dtb \
                   -display none" \
        -asu-args "-M riscv-fdt \
                   -hw-dtb $DTB_DIR/board-versal2-asu-virt.dtb \
                   -display none" \
        -display none "$@"
    '';
  };
}
