{
  config,
  pkgs,
  modulesPath,
  options,
  lib,
  ...
}:

# Versal AI Edge Gen 2 SD/UFS disk image.
#
# Differences from the standard nixos-xlnx sd-image (Zynq/ZynqMP):
#
#  * Partition table arithmetic is done in 4 KiB sectors (versal2 UFS
#    devices expose a 4 KiB logical-sector-size block device; with the
#    default 512-byte layout U-Boot prints
#    "FAT sector size mismatch (fs=512, dev=4096)").
#  * The firmware partition is tagged MBR type 0xEF (EFI System
#    Partition), so U-Boot's EFI BootMgr discovers it and loads
#    `/EFI/BOOT/BOOTAA64.EFI` from it.
#  * The firmware partition is formatted with `mkfs.vfat -S 4096`.
#  * The firmware partition can hold systemd-boot + kernel + initrd
#    (the realistic boot path on UFS, since U-Boot reads FAT but not
#    ext4). Selectable via `hardware.xlnx.diskImage.bootloader`.
#  * BOOT.BIN is copied to the FAT only when
#    `hardware.xlnx.bootBin.enable` is true.

let
  cfg = config.hardware.xlnx;
  diskCfg = cfg.diskImage;

  # The device backing the root mount. Resolved by readlink at boot, so
  # by-label / by-uuid / plain-device specs all work for the grow step.
  rootDevice = config.fileSystems."/".device;

  systemd-boot-efi = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";

  populateSystemdBoot = ''
    mkdir -p firmware/EFI/BOOT firmware/EFI/systemd firmware/EFI/nixos
    mkdir -p firmware/loader/entries

    install -m 0644 ${systemd-boot-efi} firmware/EFI/BOOT/BOOTAA64.EFI
    install -m 0644 ${systemd-boot-efi} firmware/EFI/systemd/systemd-bootaa64.efi

    install -m 0644 \
      $(readlink -f ${config.system.build.toplevel}/kernel) \
      firmware/EFI/nixos/Image
    install -m 0644 \
      $(readlink -f ${config.system.build.toplevel}/initrd) \
      firmware/EFI/nixos/initrd

    cat > firmware/loader/loader.conf <<EOF
    default nixos
    timeout 0
    editor  no
    EOF

    cat > firmware/loader/entries/nixos.conf <<EOF
    title   NixOS
    linux   /EFI/nixos/Image
    initrd  /EFI/nixos/initrd
    options init=${config.system.build.toplevel}/init ${lib.concatStringsSep " " config.boot.kernelParams}
    EOF
  '';
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./nixos.nix
  ];
  disabledModules = [ "${modulesPath}/profiles/all-hardware.nix" ];

  options.hardware.xlnx.diskImage = {
    sectorSize = lib.mkOption {
      type = lib.types.enum [
        512
        4096
      ];
      defaultText = lib.literalMD "4096 on versal2, 512 elsewhere";
      default = if cfg.platform == "versal2" then 4096 else 512;
      description = ''
        Logical sector size baked into the disk image's partition table
        and FAT filesystem. Set to 4096 for UFS-backed Versal2 boards
        (the default), 512 for SD-backed boards.
      '';
    };

    firmwarePartitionType = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalMD ''"ef" on versal2, "b" elsewhere'';
      default = if cfg.platform == "versal2" then "ef" else "b";
      example = "ef";
      description = ''
        MBR partition type byte for the firmware partition. `"ef"`
        marks it as the EFI System Partition (consumed by U-Boot's EFI
        BootMgr to locate `/EFI/BOOT/BOOTAA64.EFI`); `"b"` is the
        legacy W95 FAT32 type used by the Zynq/ZynqMP path.
      '';
    };

    bootloader = lib.mkOption {
      type = lib.types.enum [
        "systemd-boot"
        "extlinux"
        "none"
      ];
      default = "systemd-boot";
      description = ''
        How the kernel and initrd are made discoverable to U-Boot.

        * `"systemd-boot"` — install systemd-boot to the ESP and copy
          the kernel + initrd onto the FAT partition. U-Boot's EFI
          BootMgr loads systemd-boot from `/EFI/BOOT/BOOTAA64.EFI`,
          which then boots NixOS from `/loader/entries/nixos.conf`.
          Required on boards where U-Boot can't read the ext4 root
          (UFS/MMC controllers that only expose FAT to U-Boot).
        * `"extlinux"` — let `boot.loader.generic-extlinux-compatible`
          place `extlinux.conf` on the ext4 root. U-Boot reads ext4
          via `distro_bootcmd`. Matches the Zynq/ZynqMP path.
        * `"none"` — populate neither; the user is expected to set
          `sdImage.populateFirmwareCommands` themselves.
      '';
    };

    expandRootOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Grow the root partition and its ext4 filesystem to fill the
        underlying medium during stage-1 boot, before the root is
        mounted. The partition grown is whichever one backs
        `fileSystems."/"` (resolved via its `device`, so by-label and
        by-uuid both work).

        This replaces upstream's `sdImage.expandOnBoot` (disabled by
        this module), which is unusable here: it derives the partition
        number from the block device's *minor* number — wrong for
        `mmcblk*` — and runs as a stage-2 service, after activation has
        already failed with ENOSPC on a minimally-sized root (the
        ext4 from `make-ext4-fs` ships shrunk to its minimum + 16 MiB,
        leaving almost no free inodes). Doing the grow in stage 1 is
        also why `boot.growPartition` (a stage-2 service) and
        `systemd-repart` (needs GPT; this image is MBR) don't fit.

        Both the partition grow and the resize2fs are idempotent, so
        this is a no-op on every boot after the first. Assumes an ext4
        root; set to false for other root filesystems.
      '';
    };
  };

  config = {
    # On systemd-boot the FAT/ESP carries the kernel + initrd, so an
    # extlinux.conf on the ext4 root is never read. Force-disable the
    # `generic-extlinux-compatible` default from ./nixos.nix so it
    # doesn't write dead files into the root partition.
    boot.loader.generic-extlinux-compatible.enable =
      lib.mkIf (diskCfg.bootloader == "systemd-boot") (lib.mkForce false);

    # Grow the root partition + ext4 to fill the medium in stage 1, before
    # the root is mounted (resize2fs grow adds block groups, yielding both
    # free space and free inodes). See diskImage.expandRootOnBoot for why
    # this can't be the stage-2 expand-root-partition service.
    boot.initrd = lib.mkIf diskCfg.expandRootOnBoot {
      # Tools the grow step needs that the base initrd doesn't guarantee.
      extraUtilsCommands = ''
        [ -e $out/bin/sfdisk ]    || copy_bin_and_libs ${pkgs.util-linux}/bin/sfdisk
        [ -e $out/bin/resize2fs ] || copy_bin_and_libs ${pkgs.e2fsprogs}/bin/resize2fs
        [ -e $out/bin/e2fsck ]    || copy_bin_and_libs ${pkgs.e2fsprogs}/bin/e2fsck
      '';

      postDeviceCommands = ''
        rootPart=$(readlink -f ${rootDevice} 2>/dev/null || true)
        if [ -b "$rootPart" ]; then
          partName=''${rootPart#/dev/}
          partNum=$(cat /sys/class/block/"$partName"/partition 2>/dev/null || true)
          diskName=$(basename "$(readlink -f /sys/class/block/"$partName"/.. 2>/dev/null)" 2>/dev/null || true)
          if [ -n "$partNum" ] && [ -b "/dev/$diskName" ]; then
            echo "expanding root partition /dev/$diskName #$partNum to fill device..."
            # ",+," = keep start, grow to all free space, keep type. Idempotent: a
            # no-op once the partition already reaches the end of the device. The
            # disk isn't mounted yet here, so sfdisk's BLKRRPART re-read succeeds.
            echo ",+," | sfdisk --force -N"$partNum" "/dev/$diskName" || true
            udevadm settle || true
            rootPart=$(readlink -f ${rootDevice} 2>/dev/null || echo "$rootPart")
            # -p (preen, no -f): a quick no-op on the clean fs, just enough that
            # resize2fs won't refuse. resize2fs is itself a no-op once the fs
            # already fills the partition, so this whole block is safe every boot.
            e2fsck -p "$rootPart" || true
            resize2fs "$rootPart" || true
          fi
        fi
      '';
    };

    sdImage = {
      # Disabled in favour of the stage-1 grow; see
      # diskImage.expandRootOnBoot for why the stage-2 service is unusable here.
      expandOnBoot = lib.mkDefault false;

      # Plenty of space for BOOT.BIN, systemd-boot, kernel, and initrd.
      firmwareSize = lib.mkDefault 512;

      populateFirmwareCommands =
        (lib.optionalString (diskCfg.bootloader == "systemd-boot") populateSystemdBoot)
        + (lib.optionalString (cfg.boot-bin != null) ''
          install -m 0644 ${cfg.boot-bin} firmware/BOOT.BIN
        '');

      populateRootCommands =
        if diskCfg.bootloader == "extlinux" then
          ''
            mkdir -p ./files/boot
            ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
              -c ${config.system.build.toplevel} -d ./files/boot
          ''
        else
          # systemd-boot lives on the FAT ESP; nothing to populate on
          # the ext4 root.
          "";
    };

    # nixos-25.05 replaced profiles/all-hardware.nix with the
    # `hardware.enableAllHardware` option; guard on its presence so this
    # module works across nixpkgs versions.
    hardware = lib.optionalAttrs (options.hardware ? enableAllHardware) {
      enableAllHardware = lib.mkForce false;
    };

    environment.systemPackages = lib.optional (cfg.boot-bin != null) (
      pkgs.writeShellApplication {
        name = "xlnx-firmware-update";
        text = ''
          systemctl start boot-firmware.mount
          cp ${cfg.boot-bin} /boot/firmware/BOOT.BIN
          sync /boot/firmware/BOOT.BIN
        '';
      }
    );

    # Workaround efivar build failure on armv7l-linux
    # We don't use EFI, they're just referenced in <nixpkgs/nixos/modules/profiles/base.nix>
    nixpkgs.overlays = lib.mkIf (cfg.platform != "versal2") [
      (self: super: {
        efivar = pkgs.emptyDirectory;
        efibootmgr = pkgs.emptyDirectory;
      })
    ];

    # Replace the upstream sdImage builder with one that does 4 KiB
    # sector arithmetic and emits an ESP-typed firmware partition.
    system.build.sdImage = lib.mkForce (pkgs.callPackage (
      {
        stdenv,
        dosfstools,
        e2fsprogs,
        mtools,
        libfaketime,
        util-linux,
        zstd,
      }:
      stdenv.mkDerivation {
        name = config.image.fileName;

        nativeBuildInputs = [
          dosfstools
          e2fsprogs
          libfaketime
          mtools
          util-linux
        ]
        ++ lib.optional config.sdImage.compressImage zstd;

        inherit (config.sdImage) compressImage;

        buildCommand = ''
          mkdir -p $out/nix-support $out/sd-image
          export img=$out/sd-image/${config.image.baseName}.img

          echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
          if test -n "$compressImage"; then
            echo "file sd-image $img.zst" >> $out/nix-support/hydra-build-products
          else
            echo "file sd-image $img" >> $out/nix-support/hydra-build-products
          fi

          root_fs=${config.sdImage.rootFilesystemImage}
          ${lib.optionalString config.sdImage.compressImage ''
            root_fs=./root-fs.img
            echo "Decompressing rootfs image"
            zstd -d --no-progress "${config.sdImage.rootFilesystemImage}" -o $root_fs
          ''}

          sectorSize=${toString diskCfg.sectorSize}
          # MiB-per-sector scale: 1 MiB = 1024*1024 bytes / sectorSize sectors
          mibSectors=$(( 1024 * 1024 / sectorSize ))

          gapMiB=${toString config.sdImage.firmwarePartitionOffset}
          gapSectors=$(( gapMiB * mibSectors ))

          # Round the rootfs size up to a whole sector.
          rootBytes=$(stat -c %s $root_fs)
          rootSectors=$(( (rootBytes + sectorSize - 1) / sectorSize ))

          firmwareSectors=$(( ${toString config.sdImage.firmwareSize} * mibSectors ))

          # Total image size = gap + firmware + rootfs, expressed in bytes.
          imageSize=$(( (gapSectors + firmwareSectors + rootSectors) * sectorSize ))
          truncate -s $imageSize $img

          # sfdisk --sector-size sets *both* the on-disk geometry and
          # the units it accepts in the input script. start=/size= below
          # are in $sectorSize-byte sectors.
          sfdisk --sector-size $sectorSize --no-reread --no-tell-kernel $img <<EOF
              label: dos
              label-id: ${config.sdImage.firmwarePartitionID}

              start=$gapSectors, size=$firmwareSectors, type=${diskCfg.firmwarePartitionType}
              start=$(( gapSectors + firmwareSectors )), type=83, bootable
          EOF

          # We laid out the partition table ourselves above, so reuse
          # those offsets directly instead of round-tripping through
          # `partx --sector-size` (which normalises START/SECTORS to
          # 512-byte units regardless of the disk's logical sector size,
          # which would silently mis-place the FAT and rootfs).
          firmwareStart=$gapSectors
          rootStart=$(( gapSectors + firmwareSectors ))

          # Copy the rootfs into the SD image.
          dd conv=notrunc if=$root_fs of=$img bs=$sectorSize seek=$rootStart count=$rootSectors

          # Build the FAT filesystem in a separate file, then dd it in.
          truncate -s $(( firmwareSectors * sectorSize )) firmware_part.img

          mkfs.vfat \
            --invariant \
            -S $sectorSize \
            -F 32 \
            -i ${config.sdImage.firmwarePartitionID} \
            -n ${config.sdImage.firmwarePartitionName} \
            firmware_part.img

          mkdir firmware
          ${config.sdImage.populateFirmwareCommands}

          find firmware -exec touch --date=2000-01-01 {} +
          cd firmware
          for d in $(find . -type d -mindepth 1 | sort); do
            faketime "2000-01-01 00:00:00" mmd -i ../firmware_part.img "::/$d"
          done
          for f in $(find . -type f | sort); do
            mcopy -pvm -i ../firmware_part.img "$f" "::/$f"
          done
          cd ..

          fsck.vfat -vn firmware_part.img
          dd conv=notrunc if=firmware_part.img of=$img bs=$sectorSize seek=$firmwareStart count=$firmwareSectors

          ${config.sdImage.postBuildCommands}

          if test -n "$compressImage"; then
              zstd -T$NIX_BUILD_CORES --rm $img
          fi
        '';
      }
    ) { });
  };
}
