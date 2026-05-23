{
  lib,
  python3Packages,
  fetchFromGitHub,
}:

# AMD's `qemu-system-amd-fpga-multiarch` wrapper: parses `-bootbin`,
# `-plm-args`, `-asu-args` etc., extracts firmware partitions from a
# Versal2 BOOT.BIN, and spawns the right combination of
# qemu-system-microblazeel (PMC PLM), qemu-system-riscv32 (ASU), and
# qemu-system-aarch64 (APU). This is what Yocto's `runqemu` invokes
# under the hood.
#
# This derivation installs both the Python module the wrapper imports
# (`amd_boot_image_loader`) and the wrapper script itself. The wrapper
# expects to find `qemu-system-*` and `bootgen` next to it — use
# `qemu-xlnx-multiarch` (a `symlinkJoin`) to put them all in one bin/.

python3Packages.buildPythonApplication rec {
  pname = "qemu-bootbin-helper";
  version = "2026.1-unstable-2026-05-08";

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "qemu-bootbin-helper";
    rev = "f984c6c5c888a5b83230970c651a0fcd8f802b4f";
    hash = "sha256-qyMzYsMoYb5n4y3XUNPyFYjTIWpsdEOAeq8OQq8Twmo=";
  };

  format = "setuptools";

  postInstall = ''
    install -Dm755 qemu-system-amd-fpga-multiarch $out/bin/qemu-system-amd-fpga-multiarch
    # Patch the shebang to use the python interpreter we built against.
    sed -i "1s|^#!/usr/bin/env python3$|#!${python3Packages.python.interpreter}|" \
      $out/bin/qemu-system-amd-fpga-multiarch
  '';

  # The wrapper imports amd_boot_image_loader at the top; nothing else.
  doCheck = false;

  meta = {
    description = "AMD QEMU multiarch wrapper (BOOT.BIN → PLM/ASU/APU orchestration)";
    homepage = "https://github.com/Xilinx/qemu-bootbin-helper";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
