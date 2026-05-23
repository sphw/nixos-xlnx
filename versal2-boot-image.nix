{
  config,
  pkgs,
  lib,
  ...
}:

# Generates the canonical Versal AI Edge Gen 2 multi-image BOOT.BIN layout from
# a set of vendor PDI blobs, so carrier boards only supply paths rather than
# hand-rolling `hardware.xlnx.bif.images`. Active once
# `hardware.xlnx.versal2.pmcData` is set; inert otherwise.
#
# The PLM, bl31, dtb and U-Boot come from the existing `hardware.xlnx.plm` /
# `hardware.xlnx.dtb` options and the `armTrustedFirmwareVersal2` / `ubootVersal2`
# packages, so they are not re-specified here.

let
  cfg = config.hardware.xlnx;
  v = cfg.versal2;

  cdo = id: value: {
    attributes = [
      "id = ${id}"
      "type = cdo"
    ];
    inherit value;
  };
in
{
  options.hardware.xlnx.versal2 = {
    pmcData = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        PMC platform-init CDO, loaded at 0xf2000000 in the `pmc_subsys`
        image. Setting this enables the generated multi-image BIF.
      '';
    };
    lpdData = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "LPD power-domain CDO (the `lpd` image).";
    };
    fpdData = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "FPD power-domain CDO (the `fpd` image).";
    };
    plCfiMarkers = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "PL CFI boot markers (the `pl_cfi_markers` image).";
    };
    asuData = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        ASU data CDO. The `asufw` image is emitted only when both this and
        {option}`hardware.xlnx.versal2.asufw` are set.
      '';
    };
    asufw = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "ASU firmware ELF (the `core = asu` partition of the `asufw` image).";
    };
    pldPartitions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Partition id, e.g. `0x105`.";
            };
            value = lib.mkOption {
              type = lib.types.either lib.types.str lib.types.path;
              description = "Path to the PLD partition payload (rcdo/rnpi).";
            };
          };
        }
      );
      default = [ ];
      description = ''
        PL fabric configuration partitions (the `pl_cfi_logic` image),
        emitted in list order. Empty (the default) omits the image.
      '';
    };
    dtbLoadAddr = lib.mkOption {
      type = lib.types.str;
      default = "0x01000000";
      description = ''
        Load address for the DTB raw partition in the `apu_subsystem` image.
        Must match U-Boot's `CONFIG_XILINX_OF_BOARD_DTB_ADDR`.
      '';
    };
  };

  config = lib.mkIf (v.pmcData != null) {
    # The pmc_subsys/lpd/fpd/pl_cfi_markers images are emitted unconditionally
    # once pmcData is set, so their CDOs must be supplied — otherwise bootgen
    # gets an empty `file =` and fails with an opaque error.
    assertions = [
      {
        assertion = v.lpdData != null;
        message = "hardware.xlnx.versal2.lpdData must be set when versal2.pmcData is set (it is the `lpd` image's CDO).";
      }
      {
        assertion = v.fpdData != null;
        message = "hardware.xlnx.versal2.fpdData must be set when versal2.pmcData is set (it is the `fpd` image's CDO).";
      }
      {
        assertion = v.plCfiMarkers != null;
        message = "hardware.xlnx.versal2.plCfiMarkers must be set when versal2.pmcData is set (it is the `pl_cfi_markers` image's CDO).";
      }
    ];

    hardware.xlnx.bif.images = lib.mkDefault (
      [
        {
          name = "pmc_subsys";
          id = "0x1c000001";
          partitions = [
            {
              attributes = [
                "id = 0x01"
                "type = bootloader"
              ];
              value = cfg.plm;
            }
            {
              attributes = [
                "id = 0x09"
                "type = pmcdata, load = 0xf2000000"
              ];
              value = v.pmcData;
            }
          ];
        }
        {
          name = "lpd";
          id = "0x4210002";
          partitions = [ (cdo "0x0C" v.lpdData) ];
        }
        {
          name = "fpd";
          id = "0x420c003";
          partitions = [ (cdo "0x08" v.fpdData) ];
        }
        {
          name = "pl_cfi_markers";
          id = "0x18700000";
          partitions = [ (cdo "0x05" v.plCfiMarkers) ];
        }
      ]
      ++ lib.optional (v.asuData != null && v.asufw != null) {
        name = "asufw";
        id = "0x1C000002";
        partitions = [
          (cdo "0x0F" v.asuData)
          {
            attributes = [
              "id = 0x0B"
              "core = asu"
            ];
            value = v.asufw;
          }
        ];
      }
      ++ lib.optional (v.pldPartitions != [ ]) {
        name = "pl_cfi_logic";
        id = "0x18700001";
        partitions = map (p: cdo p.id p.value) v.pldPartitions;
      }
      ++ [
        {
          # APU subsystem we build ourselves: BL31 (EL3) hands off to
          # U-Boot (EL2), which reads its live DTB from dtbLoadAddr.
          name = "apu_subsystem";
          id = "0x1c000000";
          partitions = [
            {
              attributes = [
                "core = a78-0"
                "cluster = 0"
                "exception_level = el-3"
                "trustzone"
              ];
              value = "${pkgs.armTrustedFirmwareVersal2}/bl31.elf";
            }
            {
              attributes = [
                "type = raw"
                "load = ${v.dtbLoadAddr}"
              ];
              value = "${cfg.dtb}";
            }
            {
              attributes = [
                "core = a78-0"
                "cluster = 0"
                "exception_level = el-2"
              ];
              value = "${pkgs.ubootVersal2}/u-boot.elf";
            }
          ];
        }
      ]
    );
  };
}
