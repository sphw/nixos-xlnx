{
  xlnxVersion ? "2025.1",
}:
final: prev: {

  inherit (prev.callPackages ./pkgs/embeddedsw.nix { inherit xlnxVersion; })
    zynqmp-fsbl
    zynqmp-pmufw
    zynq-fsbl
    versal2-plm
    ;
  ubootZynqMP = prev.callPackage ./pkgs/u-boot-xlnx.nix {
    inherit xlnxVersion;
    platform = "zynqmp";
  };
  ubootZynq = prev.callPackage ./pkgs/u-boot-xlnx.nix {
    inherit xlnxVersion;
    platform = "zynq";
  };
  ubootVersal2 = prev.callPackage ./pkgs/u-boot-xlnx.nix {
    inherit xlnxVersion;
    platform = "versal2";
  };
  armTrustedFirmwareZynqMP = prev.callPackage ./pkgs/arm-trusted-firmware-xlnx.nix {
    inherit xlnxVersion;
  };
  armTrustedFirmwareVersal2 = prev.callPackage ./pkgs/arm-trusted-firmware-xlnx.nix {
    inherit xlnxVersion;
    platform = "versal2";
  };
  linux_zynqmp = prev.callPackage ./pkgs/linux-xlnx {
    inherit xlnxVersion;
    defconfig = "xilinx_defconfig";
    kernelPatches = [ ];
  };
  linux_zynq = prev.callPackage ./pkgs/linux-xlnx {
    inherit xlnxVersion;
    defconfig = "xilinx_zynq_defconfig";
    kernelPatches = [ ];
  };
  linux_versal2 = prev.callPackage ./pkgs/linux-xlnx {
    inherit xlnxVersion;
    defconfig = "xilinx_defconfig";
    kernelPatches = [ ];
  };
  linuxPackages_zynqmp = (prev.linuxKernel.packagesFor final.linux_zynqmp).extend final.xlnxExtraLinuxPackages;
  linuxPackages_zynq = (prev.linuxKernel.packagesFor final.linux_zynq).extend final.xlnxExtraLinuxPackages;
  linuxPackages_versal2 = (prev.linuxKernel.packagesFor final.linux_versal2).extend final.xlnxExtraLinuxPackages;

  xlnxExtraLinuxPackages = kfinal: kprev: {
    xlnx-hdmi-modules = kprev.callPackage ./pkgs/hdmi-modules.nix { };
    xlnx-dp-modules = kprev.callPackage ./pkgs/dp-modules.nix { };
    xlnx-vcu-modules = kprev.callPackage ./pkgs/vcu-modules.nix { };
    mali-module-xlnx = kprev.callPackage ./pkgs/mali-module-xlnx.nix { };
    xlnx-dma-proxy = kprev.callPackage ./pkgs/dma-proxy.nix { };
    bperez77-xilinx-axidma = kprev.callPackage ./pkgs/xilinx-axidma.nix { };
    jacobfeder-axisfifo = kprev.callPackage ./pkgs/axisfifo.nix { };
    digilent-hdmi = kprev.callPackage ./pkgs/digilent-hdmi.nix { };
    digilent-dynclk = kprev.callPackage ./pkgs/digilent-dynclk.nix { };
  };
  xlnx-vcu-firmware = prev.callPackage ./pkgs/vcu-firmware.nix { inherit xlnxVersion; };

  libmali-xlnx = prev.callPackages ./pkgs/libmali-xlnx.nix { inherit xlnxVersion; };
  libomxil-xlnx = prev.callPackage ./pkgs/libomxil-xlnx.nix { inherit xlnxVersion; };
  libvcu-xlnx = prev.callPackage ./pkgs/libvcu-xlnx.nix { inherit xlnxVersion; };

  xorg = prev.xorg // {
    xf86videoarmsoc = prev.callPackage ./pkgs/xf86-video-armsoc.nix { inherit xlnxVersion; };
  };

  gst_all_1 = prev.gst_all_1 // {
    gst-omx-zynqultrascaleplus =
      (prev.callPackage ./pkgs/gst-omx.nix { omxTarget = "zynqultrascaleplus"; }).overrideAttrs
        (super: {
          mesonFlags = super.mesonFlags ++ [
            (prev.lib.mesonOption "header_path" "${final.libomxil-xlnx}/include/vcu-omx-il")
          ];
          postPatch = super.postPatch + ''
            substituteInPlace config/zynqultrascaleplus/gstomx.conf --replace "/usr" "${final.libomxil-xlnx}"
          '';
        });
  };

  "xilinx-bootgen_${prev.lib.replaceString "." "_" xlnxVersion}" = prev.xilinx-bootgen.overrideAttrs (old: rec {
    version = "xilinx_v${xlnxVersion}";
    src = prev.fetchFromGitHub {
      owner = "Xilinx";
      repo = "bootgen";
      rev = version;
      hash =
        {
          "2024.1" = "sha256-/gNAqjwfaD2NWxs2536XGv8g2IyRcQRHzgLcnCr4a34=";
          "2025.1" = "sha256-VMmqNaptD6pEJDVSmmOvHcEl+5WUfwZMwxDoaiDPdxg=";
          "2025.2" = "sha256-F1daWkZwcvejmtjF5xjGvE9Y9FrYVsGNreRWVdacjIk=";
        }
        .${xlnxVersion};
    };
    # Xilinx bootgen 2025.2 uses `printf` in lms-hash-sigs/hss_param.c
    # without `#include <stdio.h>`; gcc 14+ treats that as a hard error.
    # Demote it back to a warning.
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = toString [
        (old.env.NIX_CFLAGS_COMPILE or "")
        "-Wno-error=implicit-function-declaration"
        "-Wno-error=int-conversion"
        "-Wno-error=incompatible-pointer-types"
      ];
    };
    installPhase = ''
      install -Dm755 ${
        if prev.lib.versionAtLeast xlnxVersion "2025.1" then "build/bin/bootgen" else "bootgen"
      } $out/bin/bootgen
    '';
  });
  python-lopper = prev.python3Packages.callPackage ./pkgs/lopper.nix { };

  qemu-xlnx = prev.callPackage ./pkgs/qemu-xlnx.nix { inherit xlnxVersion; };
  qemu-devicetrees-xlnx = prev.callPackage ./pkgs/qemu-devicetrees.nix { inherit xlnxVersion; };
  # Build-time software-DTB helpers for the Versal2 QEMU paths
  # (`.dumpedDtb { bootargs = ...; }` and `.hwDtb { bootargs = ...; hwDtb ? "..."; }`).
  versal2-qemu-swdtb = prev.callPackage ./pkgs/versal2-qemu-swdtb.nix { };

  qemu-bootbin-helper = prev.callPackage ./pkgs/qemu-bootbin-helper.nix { };

  # `qemu-system-amd-fpga-multiarch` (from qemu-bootbin-helper) hunts
  # for `qemu-system-{aarch64,microblazeel,riscv32}` first next to its
  # own __file__ and then via PATH (`shutil.which`). buildPythonApplication
  # interposes a shell wrapper that exec's the real Python script from
  # the helper's own bin/, so `__file__`-based discovery picks up the
  # helper's bin only — which doesn't contain qemu. Make a fresh
  # symlinkJoin with everything and replace the wrapper with one that
  # puts $out/bin on PATH so the helper's `shutil.which` fallback wins.
  qemu-xlnx-multiarch = prev.symlinkJoin {
    name = "qemu-xlnx-multiarch-${xlnxVersion}";
    paths = [
      final.qemu-xlnx
      final.qemu-bootbin-helper
      final."xilinx-bootgen_${prev.lib.replaceString "." "_" xlnxVersion}"
    ];
    postBuild = ''
      rm $out/bin/qemu-system-amd-fpga-multiarch
      cat > $out/bin/qemu-system-amd-fpga-multiarch <<EOF
      #!${prev.runtimeShell}
      export PATH="\$(dirname "\$(readlink -f "\$0")"):\$PATH"
      exec ${final.qemu-bootbin-helper}/bin/qemu-system-amd-fpga-multiarch "\$@"
      EOF
      chmod +x $out/bin/qemu-system-amd-fpga-multiarch
    '';
  };
}
