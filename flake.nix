{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      overlays = {
        xlnx2025_2 = import ./overlay.nix { xlnxVersion = "2025.2"; };
        xlnx2025_1 = import ./overlay.nix { xlnxVersion = "2025.1"; };
        xlnx2024_1 = import ./overlay.nix { xlnxVersion = "2024.1"; };
        # Swap the stock MicroBlaze cross toolchain for AMD's patched gcc 13 +
        # newlib (meta-xilinx). Add to `overlays` (guarded on isMicroBlaze) so
        # boot firmware built from embeddedsw source uses the supported codegen.
        microblaze-xilinx-toolchain = import ./pkgs/microblaze-xilinx-toolchain.nix;
      };
      legacyPackages = forAllSystems (system: {
        xlnx2025_2 = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.xlnx2025_2 ];
        };
        xlnx2025_1 = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.xlnx2025_1 ];
        };
        xlnx2024_1 = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.xlnx2024_1 ];
        };
      });
      nixosModules.sd-image = import ./sd-image.nix;
      # Versal AI Edge Gen 2 disk image: 4 KiB-sector partition table,
      # EFI System Partition holding systemd-boot + kernel + initrd,
      # ext4 root. Use this in place of `nixosModules.sd-image` for
      # versal2 targets (real UFS hardware and QEMU both want it).
      nixosModules.versal2-sd-image = import ./sd-image-versal2.nix;
      # Just the boot-chain wiring (BIF, BOOT.BIN, kernel/console selection),
      # without the SD image partition layout. Useful for QEMU testing or
      # when shipping a custom storage layout.
      nixosModules.xlnx = import ./nixos.nix;
    };
}
