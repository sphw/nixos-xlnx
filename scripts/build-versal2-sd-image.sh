#!/usr/bin/env bash
# Build a NixOS SD card image for Versal AI Edge Gen 2 from Vivado outputs.
#
# Usage:
#   scripts/build-versal2-sd-image.sh <sdt-dir> <dt-dir> <bitstream.pdi>
#
# Where:
#   <sdt-dir>       directory produced by `gendt.tcl ... -platform versal2`
#                   (contains system-top.dts and the SDT YAML/DTS sources)
#   <dt-dir>        device-tree sources directory from the same script
#   <bitstream.pdi> Vivado-exported .pdi (the PL programmable image)
#
# Result: a symlink ./result -> /nix/store/...-aarch64-linux.img.zst
# Flash with:
#   zstdcat ./result/sd-image/*.img.zst | sudo dd of=/dev/<sdX> bs=4M status=progress

set -euo pipefail

if [ "$#" -ne 3 ]; then
  sed -n '2,16p' "$0"
  exit 1
fi

SDT_DIR="$(cd "$1" && pwd)"
DT_DIR="$(cd "$2" && pwd)"
PDI="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

nix build --impure -L --out-link ./result --expr "
let
  flake = builtins.getFlake \"$REPO\";
  nixpkgs = flake.inputs.nixpkgs;
in (nixpkgs.lib.nixosSystem {
  system = \"aarch64-linux\";
  modules = [
    flake.nixosModules.sd-image
    ({ pkgs, lib, ... }: {
      nixpkgs.hostPlatform = \"aarch64-linux\";
      hardware.xlnx = {
        xlnxVersion = \"2025.1\";
        platform = \"versal2\";
        bitstream = $PDI;
        sdtDir   = $SDT_DIR;
        dtDir    = $DT_DIR;
      };
      users.users.root.initialPassword = \"nixos\";
      services.openssh = {
        enable = true;
        settings.PermitRootLogin = \"yes\";
      };
      boot.supportedFilesystems = lib.mkForce
        [ \"vfat\" \"ext4\" \"btrfs\" \"f2fs\" \"xfs\" ];
      system.stateVersion = \"25.11\";
    })
  ];
}).config.system.build.sdImage
"

echo
echo "Image: $(readlink -f ./result)/sd-image"
