{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.hardware.xlnx;

  # embeddedsw/cmake/toolchainfiles/cortexa9_toolchain.cmake
  fsblCross =
    if cfg.platform == "zynqmp" then
      pkgs.pkgsCross.aarch64-embedded
    else
      import pkgs.path {
        localSystem.system = pkgs.stdenv.buildPlatform.system;
        crossSystem = {
          config = "arm-none-eabihf";
          libc = "newlib";
          gcc = {
            cpu = "cortex-a9";
            fpu = "vfpv3";
            float-abi = "hard";
          };
        };
        overlays = [ (import ./overlay.nix { inherit (config.hardware.xlnx) xlnxVersion; }) ];
      };

  bifEntryType = lib.types.submodule {
    options = {
      attributes = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [
          "bootloader"
          "destination_cpu=a53-0"
        ];
        description = ''
          Bracketed attributes for this BIF entry, rendered as
          `[attr1, attr2, ...]` before the value. `null` (the default)
          emits no brackets.
        '';
      };
      value = lib.mkOption {
        type = lib.types.either lib.types.str lib.types.path;
        example = lib.literalExpression ''"''${pkgs.armTrustedFirmwareZynqMP}/bl31.elf"'';
        description = ''
          Path or string emitted after the attribute list. Usually a path
          to a binary (FSBL, PMUFW, bitstream, ELF, dtb), or a parameter string
          for attributes such as `[auth_params] ppk_select=0;spk_id=0x0`.
        '';
      };
    };
  };

  renderBifEntry =
    entry:
    let
      attrs =
        if entry.attributes == null || entry.attributes == [ ] then
          ""
        else
          "[${lib.concatStringsSep ", " entry.attributes}] ";
    in
    "${attrs}${entry.value}";
in

{
  options.hardware.xlnx = {
    platform = lib.mkOption {
      type = lib.types.enum [
        "zynq"
        "zynqmp"
        "versal2"
      ];
      description = ''
        Which Xilinx/AMD platform to target: Zynq 7000 (`zynq`),
        Zynq UltraScale+ MPSoC (`zynqmp`), or Versal AI Edge Gen 2
        / Versal Series Gen 2 (`versal2`, e.g. the VEK385 board).
      '';
    };

    sdtDir = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "./gendt/sdt";
      description = ''
        Directory to system-device-tree sources.
        Since Vivado v2024.1, it's possible to build FSBL and PMUFW in Nix.

        SDT files can be generated from XSA using {command}`./gendt.tcl`.
      '';
    };
    dtDir = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "./gendt/dt";
      description = ''
        Directory to device-tree sources.

        DT files can be generated from XSA using {command}`./gendt.tcl`.
      '';
    };
    dtb = lib.mkOption {
      type = lib.types.path;
      defaultText = lib.literalMD "built from {option}`hardware.xlnx.dtDir`";
      default = pkgs.runCommandCC "system.dtb" { nativeBuildInputs = [ pkgs.dtc ]; } ''
        ${pkgs.stdenv.cc.targetPrefix}cpp -nostdinc -undef -x assembler-with-cpp ${cfg.dtDir}/system-top.dts -isystem ${cfg.dtDir}/include -o combined.dts
        dtc -@ -I dts -O dtb combined.dts -o $out
      '';
      example = lib.literalExpression "./firmware/system.dtb";
      description = ''
        Nixos-xlnx uses this for {option}`hardware.deviceTree.dtbSource`.
        Note you can still use {option}`hardware.deviceTree.overlays` to
        update your device tree configurations.
      '';
    };

    bitstream = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "./gendt/sdt/vivado_exported.bit";
      description = ''
        Path to bitstream extracted from XSA.
        If you are using {command}`scripts/gendt.tcl`, it is extracted to the `sdt` directory.
      '';
    };
    fsbl = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      defaultText = lib.literalMD "generated from {option}`hardware.xlnx.sdtDir` on zynq/zynqmp; `null` on versal2";
      default =
        if cfg.platform == "versal2" then
          null
        else
          fsblCross."${cfg.platform}-fsbl".override { inherit (cfg) sdtDir; } + "/${cfg.platform}_fsbl.elf";
      example = lib.literalExpression "./firmware/fsbl_a53.elf";
      description = ''
        Path to First Stage Boot Loader. Not used on Versal Gen 2 —
        the PLM (see {option}`hardware.xlnx.plm`) replaces FSBL and
        PMUFW in a single firmware image.
      '';
    };
    pmufw = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      defaultText = lib.literalMD "generated from {option}`hardware.xlnx.sdtDir`";
      default =
        if cfg.platform == "zynqmp" then
          pkgs.pkgsCross.microblaze-embedded.zynqmp-pmufw.override { inherit (cfg) sdtDir; }
          + "/zynqmp_pmufw.elf"
        else
          null;
      example = lib.literalExpression "./firmware/pmufw.elf";
      description = ''
        Path to Zynq MPSoC Platform Management Unit Firmware.
      '';
    };
    plm = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      defaultText = lib.literalMD "generated from {option}`hardware.xlnx.sdtDir` on versal2";
      default =
        if cfg.platform == "versal2" then
          pkgs.pkgsCross.microblaze-embedded.versal2-plm.override { inherit (cfg) sdtDir; }
          + "/versal_plm.elf"
        else
          null;
      example = lib.literalExpression "./firmware/versal_plm.elf";
      description = ''
        Path to the Versal Platform Loader and Manager firmware
        (MicroBlaze image running on the PMC PPU). Only used on
        Versal Gen 2; subsumes FSBL and PMUFW from the ZynqMP era.
      '';
    };

    bif = {
      imageName = lib.mkOption {
        type = lib.types.str;
        default = "the_ROM_image";
        description = ''
          Image name for the BIF (the identifier before the opening brace).
          Rarely needs to be changed.
        '';
      };

      entries = lib.mkOption {
        type = lib.types.listOf bifEntryType;
        default =
          let
            dtb = "${config.hardware.deviceTree.package}/system.dtb";
          in
          {
            zynqmp = [
              {
                attributes = [
                  "bootloader"
                  "destination_cpu=a53-0"
                ];
                value = cfg.fsbl;
              }
              {
                attributes = [ "pmufw_image" ];
                value = cfg.pmufw;
              }
              {
                attributes = [ "destination_device=pl" ];
                value = cfg.bitstream;
              }
              {
                attributes = [
                  "destination_cpu=a53-0"
                  "exception_level=el-3"
                  "trustzone"
                ];
                value = "${pkgs.armTrustedFirmwareZynqMP}/bl31.elf";
              }
              {
                attributes = [
                  "destination_cpu=a53-0"
                  "load=0x00100000"
                ];
                value = dtb;
              }
              {
                attributes = [
                  "destination_cpu=a53-0"
                  "exception_level=el-2"
                ];
                value = "${pkgs.ubootZynqMP}/u-boot.elf";
              }
            ];
            zynq = [
              {
                attributes = [ "bootloader" ];
                value = cfg.fsbl;
              }
              { value = cfg.bitstream; }
              { value = "${pkgs.ubootZynq}/u-boot.elf"; }
              {
                attributes = [ "load=0x00100000" ];
                value = dtb;
              }
            ];
            versal2 = [
              {
                attributes = [
                  "bootloader"
                  "destination_cpu=pmc"
                ];
                value = cfg.plm;
              }
              {
                attributes = [ "destination_device=pl" ];
                value = cfg.bitstream;
              }
              {
                attributes = [
                  "destination_cpu=a78-0"
                  "exception_level=el-3"
                  "trustzone"
                ];
                value = "${pkgs.armTrustedFirmwareVersal2}/bl31.elf";
              }
              {
                attributes = [
                  "destination_cpu=a78-0"
                  "load=0x00100000"
                ];
                value = dtb;
              }
              {
                attributes = [
                  "destination_cpu=a78-0"
                  "exception_level=el-2"
                ];
                value = "${pkgs.ubootVersal2}/u-boot.elf";
              }
            ];
          }
          .${cfg.platform};
        defaultText = lib.literalMD ''
          Platform-specific list of FSBL, PMUFW, bitstream, ATF, U-Boot, and dtb entries.
        '';
        example = lib.literalExpression ''
          options.hardware.xlnx.bif.entries.default ++ [
            {
              attributes = [
                "destination_cpu=a53-0"
                "exception_level=el-1"
                "trustzone"
              ];
              value = "''${pkgs.opteeOsZynqMP}/tee.elf";
            }
          ]
        '';
        description = ''
          Structured list of BIF entries. Each entry renders as
          `[attr1, attr2] value`.
        '';
      };

      text = lib.mkOption {
        type = lib.types.str;
        defaultText = lib.literalMD ''
          Built from {option}`hardware.xlnx.bif.imageName` and
          {option}`hardware.xlnx.bif.entries`.
        '';
        description = ''
          The full BIF text passed to bootgen. Override directly for full
          control (e.g. multi-image partitions).
        '';
      };

      file = lib.mkOption {
        type = lib.types.path;
        defaultText = lib.literalMD ''
          {option}`hardware.xlnx.bif.text` written to a file in the Nix store.
        '';
        description = ''
          The BIF written out as a file. Useful for invoking `bootgen`
          manually outside the Nix store, e.g. when secret AES/RSA keys
          should not end up world-readable in `/nix/store`:

          ```
          nix build .#nixosConfigurations.<hostname>.config.hardware.xlnx.bif.file
          bootgen -image ./result -arch zynqmp -p xczu9eg -encrypt efuse -w -o BOOT.BIN
          ```
        '';
      };
    };

    boot-bin = lib.mkOption {
      type = lib.types.path;
      defaultText = lib.literalMD "built by bootgen from {option}`hardware.xlnx.bif.file`";
      description = ''
        You can build BOOT.BIN without building the whole system using
        {command}`nix build .#nixosConfigurations.<hostname>.config.hardware.xlnx.boot-bin`
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.platform == "zynqmp" -> cfg.pmufw != null;
        message = "hardware.xlnx.pmufw is not optional on ZynqMP.";
      }
      {
        assertion = cfg.platform != "versal2" -> cfg.fsbl != null;
        message = "hardware.xlnx.fsbl is not optional on Zynq/ZynqMP.";
      }
      {
        assertion = cfg.platform == "versal2" -> cfg.plm != null;
        message = "hardware.xlnx.plm is not optional on Versal Gen 2.";
      }
    ];

    hardware.xlnx.bif.text = lib.mkDefault ''
      ${cfg.bif.imageName}: {
      ${lib.concatMapStringsSep "\n" (l: "  ${l}") (map renderBifEntry cfg.bif.entries)}
      }
    '';

    hardware.xlnx.bif.file = lib.mkDefault (pkgs.writeText "bootgen.bif" cfg.bif.text);

    hardware.xlnx.boot-bin =
      let
        bootgenArch =
          {
            zynq = "zynq";
            zynqmp = "zynqmp";
            versal2 = "versal_2ve_2vm";
          }
          .${cfg.platform};
      in
      lib.mkDefault (
        pkgs.runCommand "BOOT.BIN" { nativeBuildInputs = [ pkgs."xilinx-bootgen_${lib.replaceString "." "_" cfg.xlnxVersion}" ]; } ''
          bootgen -image ${cfg.bif.file} -arch ${bootgenArch} -w -o $out
        ''
      );
  };
}
