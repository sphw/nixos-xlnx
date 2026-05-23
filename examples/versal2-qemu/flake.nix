{
  description = "Minimal NixOS Versal AI Edge Gen 2 configuration for QEMU testing";

  inputs = {
    # Pull nixos-xlnx from this checkout; replace with the github reference
    # (`github:chuangzhu/nixos-xlnx`) if using this example outside the repo.
    nixos-xlnx.url = "path:../..";
  };

  outputs =
    { self, nixos-xlnx, ... }:
    let
      nixpkgs = nixos-xlnx.inputs.nixpkgs;

      qemuPkgs = import nixpkgs {
        system = "aarch64-linux";
        overlays = [ nixos-xlnx.overlays.xlnx2025_1 ];
      };

      nixosCfg = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";

        modules = [
          # Versal2 disk image: 4 KiB-sector ESP holding systemd-boot
          # + kernel + initrd, ext4 root. Real silicon (UFS) and the
          # multiarch QEMU wrapper both consume this exact layout.
          nixos-xlnx.nixosModules.versal2-sd-image

          (
            { lib, ... }:
            {
              nixpkgs.pkgs = qemuPkgs;

              hardware.xlnx = {
                xlnxVersion = "2025.1";
                platform = "versal2";

                # No BOOT.BIN for the QEMU smoke path: the bootloader
                # chain is loaded via `-device loader` directly, not
                # packaged through bootgen. The runner packages take
                # care of loading bl31/uboot/kernel/initrd.
                bootBin.enable = false;
              };

              # Console on the same UART as BL31/U-Boot. Linux's
              # ttyAMA enumeration follows MMIO order: ttyAMA0 is
              # serial@f1920000 (null'd by the wrapper) and ttyAMA1 is
              # serial@f1930000 (our stdio).
              boot.kernelParams = lib.mkForce [
                "earlycon=pl011,0xf1930000"
                "console=ttyAMA1,115200n8"
              ];

              users.users.root.initialPassword = "nixos";
              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "yes";
              };

              networking.hostName = "qemu-versal2";

              system.stateVersion = "25.11";
            }
          )
        ];
      };

      runners = import "${nixos-xlnx}/qemu-versal2-runners.nix" {
        pkgs = qemuPkgs;
        lib = nixpkgs.lib;
        inherit nixosCfg;
      };

    in
    {
      nixosConfigurations.qemu-versal2 = nixosCfg;

      packages.aarch64-linux = {
        # Three QEMU entry points, each fully self-contained:
        #   nix run .#qemu-versal2-upstream
        #   nix run .#qemu-versal2-downstream
        #   nix run .#qemu-versal2-multiarch -- --prebuilt-dir ~/vek385-prebuilt
        qemu-versal2-upstream   = runners.upstream;
        qemu-versal2-downstream = runners.downstream;
        qemu-versal2-multiarch  = runners.multiarch;

        # Convenience: the disk image alone, for inspection or for
        # writing to real UFS/SD media.
        sdImage = nixosCfg.config.system.build.sdImage;
      };
    };
}
