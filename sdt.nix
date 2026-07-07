# Lopper-based System Device Tree (SDT) pipeline: prune the multi-processor
# SDT exported by Vivado/sdtgen (`hardware.xlnx.sdtDir`, see scripts/gendt.tcl)
# into per-processor views at build time, so boards go straight from the SDT
# export to a bootable image without committing generated device trees.
#
# Two views are derived with lopper's `gen_domain_dts` assist:
#   * the Linux domain DT (plus optional board .dtsi overlays) -> hardware.xlnx.dtb
#   * the PMC/MicroBlaze SDT view -> the from-source PLM build (boot-bin.nix)
#
# AMD's reference flow (Buildroot/Yocto) optionally runs the `xlnx_overlay_dt`
# assist first. That assist is deliberately NOT used here: it emits a runtime
# fragment@N overlay for the FPGA-manager/DFX flow where Linux programs the PL
# after boot. On boards where the PL is configured at boot by the PLM from
# BOOT.BIN's pl_cfi_* partitions (hardware.xlnx.versal2.pldPartitions), the
# correct shape is what gen_domain_dts alone produces: the PL peripherals live
# in the main DT under amba_pl, the fpga-region node carries no firmware-name,
# and nothing re-programs the fabric at runtime.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.xlnx;
  sdt = cfg.sdt;

  # lopper / dtc / cpp run on the build machine and emit architecture-neutral
  # device trees, so they come from buildPackages: under cross-compile pkgs.*
  # is the target host set whose binaries can't execute on the builder.
  buildPkgs = pkgs.buildPackages;
  lopperLops = "${buildPkgs.python-lopper}/${buildPkgs.python3.sitePackages}/lopper/lops";
  lopperAssists = "${buildPkgs.python-lopper}/${buildPkgs.python3.sitePackages}/lopper/assists";

  # Prune the SDT into one processor's view with the gen_domain_dts assist.
  # Two non-obvious requirements: the assist + its args go after `--` (NOT via
  # a lop file), and LOPPER_DTC_FLAGS must carry `-@` so the input SDT keeps
  # the __symbols__ node the assist reads (`-b 0` matches AMD's reference
  # invocation; verified to not change the output).
  # preLops: lop files (relative to lopper's lops/) applied via -i before the
  # gen_domain_dts output assist.
  mkSdtView =
    name: genArgs: preLops:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          buildPkgs.python-lopper
          buildPkgs.stdenv.cc
          buildPkgs.dtc
        ];
        LOPPER_DTC_FLAGS = "-b 0 -@";
        # lopper locates its preprocessor with `which cpp`. Under cross,
        # buildPkgs.gcc is the target-prefixed wrapper whose bin/ has no plain
        # cpp — pin LOPPER_CPP to the native build cc, which carries an
        # unprefixed cpp that just preprocesses the SDT text.
        LOPPER_CPP = "${buildPkgs.stdenv.cc}/bin/cpp";
      }
      ''
        # Copy the SDT locally (the store dir is read-only; lopper writes a
        # .pp next to its input) and let cpp resolve #includes from the SDT
        # dir itself plus its include/ tree.
        cp -r ${cfg.sdtDir} sdt && chmod -R +w sdt
        lopper -f --enhanced -A ${lopperAssists} -I "$PWD/sdt:$PWD/sdt/include" \
          ${lib.concatMapStringsSep " " (l: "-i ${lopperLops}/${l}") preLops} \
          sdt/system-top.dts $out -- gen_domain_dts ${genArgs}
      '';
in
{
  options.hardware.xlnx.sdt = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.platform == "versal2" && cfg.sdtDir != null;
      defaultText = lib.literalMD "`true` on versal2 when {option}`hardware.xlnx.sdtDir` is set";
      description = ''
        Run lopper's `gen_domain_dts` assist over {option}`hardware.xlnx.sdtDir`
        to derive the Linux device tree ({option}`hardware.xlnx.dtb`) and the
        PMC SDT view (fed to the from-source PLM) at build time.
      '';
    };

    linuxProc = lib.mkOption {
      type = lib.types.str;
      default =
        {
          versal2 = "cortexa78_0";
          zynqmp = "psu_cortexa53_0";
          zynq = "ps7_cortexa9_0";
        }
        .${cfg.platform};
      defaultText = lib.literalMD "`\"cortexa78_0\"` on versal2";
      description = ''
        Label of the Linux boot CPU in the SDT's `cpus` node
        (`gen_domain_dts <proc> linux_dt`).
      '';
    };

    pmcProc = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if cfg.platform == "versal2" then "pmc_0" else null;
      defaultText = lib.literalMD "`\"pmc_0\"` on versal2, `null` otherwise";
      description = ''
        Label of the PMC/PLM processor in the SDT's `cpus` node; `null` skips
        the PMC view. Note: depending on the SDT vintage the label may be
        `pmc_0` or `psx_pmc_0` — check the cpus node of your `versal2.dtsi`.
      '';
    };

    linuxLops = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional (cfg.platform == "versal2") "lop-a78-imux.dts";
      defaultText = lib.literalMD "`[ \"lop-a78-imux.dts\" ]` on versal2";
      description = ''
        Lop files (relative to lopper's `lops/` directory) applied via `-i`
        before `gen_domain_dts` on the Linux view. The default
        `lop-a78-imux.dts` resolves the SDT's interrupt-multiplex into direct
        `&gic` interrupt-parents — without it Linux's fw_devlink reports an
        /apu-bus/interrupt-controller dependency cycle.
      '';
    };

    extraDtsi = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ ./dts/system-user.dtsi ]";
      description = ''
        Board overlay `.dtsi` files `/include/`d (by basename, which must
        therefore be unique) after the generated Linux DT, merged by
        `dtc -@` into the final dtb in list order.
      '';
    };

    linuxDts = lib.mkOption {
      type = lib.types.path;
      defaultText = lib.literalMD "lopper-generated from {option}`hardware.xlnx.sdtDir`";
      description = ''
        The pruned Linux-domain device tree source. Overridable; consumed by
        the {option}`hardware.xlnx.dtb` default. Also exposed as
        `system.build.sdtLinuxDts` for regeneration diffs.
      '';
    };

    pmcSdtDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      defaultText = lib.literalMD "lopper-generated, wrapped as `<dir>/system-top.dts`";
      description = ''
        Directory holding the pruned PMC SDT view as `system-top.dts` (the
        layout embeddedsw's `create_bsp.py` expects), or `null` when
        {option}`hardware.xlnx.sdt.pmcProc` is `null`. Feeds the from-source
        PLM default in boot-bin.nix. Also exposed as
        `system.build.sdtPmcSdtDir`.
      '';
    };
  };

  config = lib.mkIf sdt.enable {
    hardware.xlnx.sdt.linuxDts = lib.mkDefault (
      mkSdtView "linux-domain.dts" "${sdt.linuxProc} linux_dt" sdt.linuxLops
    );

    hardware.xlnx.sdt.pmcSdtDir = lib.mkDefault (
      if sdt.pmcProc == null then
        null
      else
        pkgs.runCommand "pmc-sdt" { } ''
          mkdir -p $out
          cp ${mkSdtView "pmc-system-top.dts" sdt.pmcProc [ ]} $out/system-top.dts
        ''
    );

    # /include/ the board overlays at the end of the generated Linux DT so
    # dtc merges them all into one root.
    hardware.xlnx.dtb = lib.mkDefault (
      pkgs.runCommand "system.dtb" { nativeBuildInputs = [ buildPkgs.dtc ]; } ''
        cat ${sdt.linuxDts} > merged.dts
        ${lib.concatMapStringsSep "\n" (d: ''
          echo '/include/ "${baseNameOf d}"' >> merged.dts
          cp ${d} ${baseNameOf d}
        '') sdt.extraDtsi}
        dtc -@ -I dts -O dtb -o $out merged.dts
      ''
    );

    # Regeneration/diff helpers:
    #   nix build .#nixosConfigurations.<name>.config.system.build.sdtLinuxDts
    system.build.sdtLinuxDts = sdt.linuxDts;
    system.build.sdtPmcSdtDir = sdt.pmcSdtDir;
  };
}
