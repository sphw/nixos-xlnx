{
  lib,
  stdenv,
  fetchFromGitHub,
  buildPackages,
  dtc,
  python3,
  xlnxVersion ? "2025.1",
}:

# Hardware DTBs consumed by AMD's downstream QEMU fork
# (`qemu-xlnx` + `-M arm-generic-fdt -hw-dtb …`). The repo contains a
# Makefile that runs `cpp` (for `#include`/`#define` preprocessing) and
# then `dtc` over every `board-*.dts`, producing
# `LATEST/{SINGLE_ARCH,MULTI_ARCH,LQSPI_XIP}/board-*.dtb`.

stdenv.mkDerivation {
  pname = "qemu-devicetrees-xlnx";
  version = "xilinx-v${xlnxVersion}";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "qemu-devicetrees";
    rev = "xilinx_v${xlnxVersion}";
    hash =
      {
        "2024.1" = lib.fakeHash;
        "2025.1" = "sha256-rXC+QXJk658g062NHpJr+dWR6laW95sJlY8Fzz8bPP8=";
      }
      .${xlnxVersion};
  };

  nativeBuildInputs = [
    dtc
    # Some auto-generated .dtsi files invoke `python3` via the Makefile.
    python3
  ];

  # The Makefile shells out to `gcc` (for `cpp` preprocessing) and `dtc`.
  # On darwin the system `gcc` is clang in disguise, which is fine for
  # `-E -nostdinc -x assembler-with-cpp`.
  makeFlags = [
    "DTC=${dtc}/bin/dtc"
    "GCC=${buildPackages.stdenv.cc.targetPrefix}cc"
  ];

  enableParallelBuilding = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    for d in SINGLE_ARCH MULTI_ARCH LQSPI_XIP; do
      if [ -d LATEST/$d ]; then
        mkdir -p $out/$d
        # Drop the preprocessor intermediates (.dts.i, .dtb.cd); keep dtbs only.
        find LATEST/$d -maxdepth 1 -name '*.dtb' -exec cp {} $out/$d/ \;
      fi
    done
    runHook postInstall
  '';

  meta = {
    description = "Hardware DTBs for AMD's downstream QEMU fork (arm-generic-fdt machine)";
    homepage = "https://github.com/Xilinx/qemu-devicetrees";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
  };
}
