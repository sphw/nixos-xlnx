{
  lib,
  stdenv,
  fetchFromGitHub,
  buildUBoot,
  platform ? "zynqmp",
  xlnxVersion ? "2025.1",
  # Board-specific patches applied on top of the Xilinx U-Boot tree
  # (e.g. iWave's IG77M HDMI patch). Same shape as buildUBoot's
  # `extraPatches`.
  extraPatches ? [ ],
  # Config fragments concatenated to the chosen defconfig before
  # `make oldconfig`. Each fragment is a file containing
  # `CONFIG_FOO=y` lines; later fragments override earlier ones.
  # Use this to enable a board-specific U-Boot header
  # (e.g. `CONFIG_VERSAL_IG77M_H=y`) without forking a new defconfig.
  extraConfigFragments ? [ ],
  # Override the defconfig entirely. Useful when the vendor patch
  # introduces a new in-tree defconfig (e.g. `versal_ig77m_defconfig`).
  defconfig ? null,
}:

let
  ubootVersion =
    {
      "2024.1" = "2024.01";
      "2025.1" = "2025.01";
      "2025.2" = "2025.01";
    }
    .${xlnxVersion};

  defaultDefconfig =
    {
      zynq = "xilinx_zynq_virt_defconfig";
      zynqmp = "xilinx_zynqmp_virt_defconfig";
      versal2 = "amd_versal2_virt_defconfig";
    }
    .${platform};

  chosenDefconfig = if defconfig != null then defconfig else defaultDefconfig;
in

buildUBoot {
  version = "${ubootVersion}-xilinx-v${xlnxVersion}";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "u-boot-xlnx";
    rev =
      {
        "2024.1" = "xlnx_rebase_v2024.01_2024.1";
        "2025.1" = "xlnx_rebase_v2025.01_2025.1";
        "2025.2" = "xlnx_rebase_v2025.01_2025.2";
      }
      .${xlnxVersion};
    hash =
      {
        "2024.1" = "sha256-G6GOcazwY4A/muG2hh4pj8i9jm536kYhirrOzcn77WE=";
        "2025.1" = "sha256-RTcd7MR37E4yVGWP3RMruyKBI4tz8ex7mY1f5F2xd00=";
        "2025.2" = "sha256-Onbe0LZ50LulRNzXKVzq10cZfxBCnhFVDVMP9wrlKxA=";
      }
      .${xlnxVersion};
  };

  defconfig = chosenDefconfig;
  inherit extraPatches;
  extraMeta.platforms = if platform == "zynq" then [ "armv7l-linux" ] else [ "aarch64-linux" ];

  # Apply config fragments after defconfig is materialised but before
  # the build runs. `make olddefconfig` propagates new symbols and
  # leaves the now-fully-resolved .config in place. We pass the
  # fragments through the Nix store so derivation purity is preserved.
  preBuild = lib.optionalString (extraConfigFragments != [ ]) ''
    for frag in ${lib.concatStringsSep " " extraConfigFragments}; do
      cat "$frag" >> .config
    done
    make olddefconfig
  '';

  filesToInstall = [ "u-boot.elf" ];
}
