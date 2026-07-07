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

  # Locate a blob by canonical name under pdiDir. The Vivado/BSP
  # hw-description export scatters them (gen_files/ for the *_data.cdo,
  # static_files/ for the ASU pair, the pl markers at the top), while a flat
  # staging copy has everything in one place — accept both.
  pdiSubdirs = [
    ""
    "/gen_files"
    "/static_files"
  ];
  findPdi =
    name:
    let
      hits = lib.filter builtins.pathExists (map (sub: v.pdiDir + "${sub}/${name}") pdiSubdirs);
    in
    if v.pdiDir != null && hits != [ ] then lib.head hits else null;
  pdiSearchHint =
    name: "${name} (searched ${lib.concatMapStringsSep ", " (s: "pdiDir${s}/") pdiSubdirs})";

  # The standard Vivado versal2 export's PL fabric partition set; boards with
  # a different set override versal2.pldPartitions directly.
  defaultPldPartitions = [
    {
      id = "0x105";
      name = "system_pld_unmask_markers.rnpi";
    }
    {
      id = "0x205";
      name = "system_pld_shutdown.rnpi";
    }
    {
      id = "0x103";
      name = "system_pld_unmask_markers.rcdo";
    }
    {
      id = "0x203";
      name = "system_pld_clear.rcdo";
    }
    {
      id = "0x303";
      name = "system_pld_markers.rcdo";
    }
    {
      id = "0x305";
      name = "system_pld_markers.rnpi";
    }
    {
      id = "0x403";
      name = "system_pld_mask.rcdo";
    }
    {
      id = "0x405";
      name = "system_pld_mask.rnpi";
    }
  ];
in
{
  options.hardware.xlnx.versal2 = {
    pdiDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./firmware";
      description = ''
        Directory holding the vendor PDI blobs by their canonical names
        (`pmc_data.cdo`, `lpd_data.cdo`, `fpd_data.cdo`,
        `system_boot_markers.rnpi`, `asu_data.cdo`, `asufw.elf`, and the
        `system_pld_*` fabric partitions). Setting this defaults all the
        other `hardware.xlnx.versal2` blob options by searching the
        directory itself plus the `gen_files/` and `static_files/`
        subdirectories, so it accepts both a flat staging copy and the BSP
        hw-description export layout (`…/extracted/system_1/pdi_files`).

        With pure flake evaluation the directory must live inside the flake
        and be tracked by git (gitignored files are invisible in the
        flake's store copy); an external absolute path needs `--impure`.
      '';
    };
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

  config = lib.mkMerge [
    (lib.mkIf (v.pdiDir != null) {
      # Blob defaults discovered from pdiDir. A missing file resolves to null
      # so it funnels into the friendly assertions below instead of an opaque
      # bootgen failure.
      hardware.xlnx.versal2 = {
        pmcData = lib.mkDefault (findPdi "pmc_data.cdo");
        lpdData = lib.mkDefault (findPdi "lpd_data.cdo");
        fpdData = lib.mkDefault (findPdi "fpd_data.cdo");
        plCfiMarkers = lib.mkDefault (findPdi "system_boot_markers.rnpi");
        asuData = lib.mkDefault (findPdi "asu_data.cdo");
        asufw = lib.mkDefault (findPdi "asufw.elf");
        pldPartitions = lib.mkDefault (
          map (p: {
            id = p.id;
            value = findPdi p.name;
          }) (lib.filter (p: findPdi p.name != null) defaultPldPartitions)
        );
      };

      assertions = [
        {
          assertion = v.pmcData != null;
          message = "hardware.xlnx.versal2.pdiDir is set but ${pdiSearchHint "pmc_data.cdo"} was not found.";
        }
      ];
    })

    (lib.mkIf (v.pmcData != null) {
      # The pmc_subsys/lpd/fpd/pl_cfi_markers images are emitted unconditionally
      # once pmcData is set, so their CDOs must be supplied — otherwise bootgen
      # gets an empty `file =` and fails with an opaque error.
      assertions = [
        {
          assertion = v.lpdData != null;
          message =
            "hardware.xlnx.versal2.lpdData must be set when versal2.pmcData is set (it is the `lpd` image's CDO)."
            + lib.optionalString (v.pdiDir != null) " ${pdiSearchHint "lpd_data.cdo"} was not found.";
        }
        {
          assertion = v.fpdData != null;
          message =
            "hardware.xlnx.versal2.fpdData must be set when versal2.pmcData is set (it is the `fpd` image's CDO)."
            + lib.optionalString (v.pdiDir != null) " ${pdiSearchHint "fpd_data.cdo"} was not found.";
        }
        {
          assertion = v.plCfiMarkers != null;
          message =
            "hardware.xlnx.versal2.plCfiMarkers must be set when versal2.pmcData is set (it is the `pl_cfi_markers` image's CDO)."
            + lib.optionalString (
              v.pdiDir != null
            ) " ${pdiSearchHint "system_boot_markers.rnpi"} was not found.";
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
    })
  ];
}
