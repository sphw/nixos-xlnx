{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  buildPackages,
  cmake,
  ninja,
  linkFarm,
  sdtDir ? null,
  xlnxVersion ? "2025.1",
  # versal2-plm knobs, overridable via `.override`:
  plmProc ? "psx_pmc_0", # PMC proc name in the SDT fed to create_bsp.py
  plmWithGloss ? true, # link nixpkgs' libgloss (false matches the vendor's .text layout)
  plmUhsMode ? false, # add the vendor's -DUHS_MODE_ENABLE
}:

let
  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "embeddedsw";
    rev = "xilinx_v${xlnxVersion}";
    hash =
      {
        "2024.1" = "sha256-vh7tdHNd3miDZplTiRP8UWhQ/HLrjMcbQXCJjTO4p9o=";
        "2025.1" = "sha256-PK8u/9zP5mVAmq4CQDRrA0dH0F7rYwJY465+7FzSHjA=";
        "2025.2" = "sha256-kYHIt+zmn+supLPZxOblVbaU969FjNPEa/qGcv5pDLY=";
      }
      .${xlnxVersion};
  };

  libmetal = stdenvNoCC.mkDerivation {
    name = "libmetal";
    version = xlnxVersion;

    src = fetchFromGitHub {
      owner = "Xilinx"; # OpenAMP
      repo = "libmetal";
      rev = "xilinx_v${xlnxVersion}";
      hash =
        {
          "2024.1" = "sha256-GNOVRbn5MfwUKpZl4cVUBAykH6YZjTXNi1Az7dj5Ez8=";
          "2025.1" = "sha256-gzTIM8rGpKH0pPaJx+8/PDII+ZFCA0DiVaOagN30Gy4=";
          "2025.2" = "sha256-2MOky+/zp1q3pt/ABA02QJ23y54/pjVRQt3Pclnm+FI=";
        }
        .${xlnxVersion};
    };

    dontBuild = true;

    # CMake 4 compatibility
    patchPhase = ''
      sed -i 's/cmake_minimum_required *(VERSION .*)/cmake_minimum_required(VERSION 3.15)/' CMakeLists.txt
    '';

    installPhase = ''
      mkdir -p $out
      cp -a . $out/
    '';
  };

  # XILINX_VITIS
  vitisDepsDir = linkFarm "embeddedsw-vitis-deps" [
    {
      name = "data/libmetal";
      path = libmetal;
    }
    # { name = "data/open-amp"; path = openamp; }
  ];

  mkEmbeddedswApp =
    {
      template,
      proc,
      postPatch ? "",
      env ? { },
      ...
    }@args:
    stdenv.mkDerivation (
      {
        pname = template;
        version = xlnxVersion;
        inherit src;

        nativeBuildInputs = [
          (buildPackages.python3.withPackages (p: [
            buildPackages.python-lopper
            p.pyyaml
            # ModuleNotFoundError: No module named 'distutils'
            p.setuptools
            p.libfdt
          ]))
          cmake
        ]
        ++ lib.optionals (lib.versionAtLeast xlnxVersion "2025.1") [
          ninja
        ];

        depsBuildBuild = [ buildPackages.stdenv.cc ]; # cpp
        # Per-app `env` overrides merge into these defaults.
        env = {
          LOPPER_DTC_FLAGS = "-@";
          XILINX_VITIS = vitisDepsDir;
          NIX_CFLAGS_COMPILE = "-Wno-error=return-mismatch -Wno-error=int-conversion -Wno-error=implicit-function-declaration";
        }
        // env;

        postPatch = ''
          # https://github.com/Xilinx/embeddedsw/issues/373
          find \( -name '*CMakeLists.txt' -o -name '*.cmake' \) -exec \
            sed -i 's/cmake_minimum_required *(VERSION .*)/cmake_minimum_required(VERSION 3.15)/' {} +
        ''
        + lib.optionalString (lib.versionAtLeast xlnxVersion "2025.1") ''
          substituteInPlace scripts/pyesw/repo.py --replace-fail "resolve_paths([shell_esw_repo])" 'resolve_paths({"set_repo_path": [shell_esw_repo]})'
        ''
        + postPatch;

        configurePhase = ''
          runHook preConfigure
          export ESW_REPO=$(readlink -f .)
          export BSP_DIR=$(mktemp -d)
          pushd $BSP_DIR
          python $ESW_REPO/scripts/pyesw/create_bsp.py -t ${template} -s ${sdtDir}/system-top.dts -p ${proc}
          popd
          # python $ESW_REPO/scripts/pyesw/build_bsp.py -d $BSP_DIR
          export APP_DIR=$(mktemp -d)
          pushd $APP_DIR
          python $ESW_REPO/scripts/pyesw/create_app.py -t ${template} -d $BSP_DIR
          popd
          runHook postConfigure
        '';

        buildPhase = ''
          runHook preBuild
          pushd $APP_DIR
          python $ESW_REPO/scripts/pyesw/build_app.py
          popd
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -Dm555 $APP_DIR/build/${template}.elf -t $out/
          runHook postInstall
        '';
        dontStrip = true;
      }
      // builtins.removeAttrs args [
        "template"
        "proc"
        "postPatch"
        "env"
      ]
    );

in

{
  zynqmp-pmufw = mkEmbeddedswApp {
    template = "zynqmp_pmufw";
    proc = "psu_pmu_0";
    postPatch = ''
      substituteInPlace cmake/toolchainfiles/microblaze-pmu_toolchain.cmake --replace-fail mb- ${stdenv.cc.targetPrefix}
    '';
    meta = {
      description = "Zynq MPSoC Platform Management Unit firmware";
      homepage = "https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18841724/PMU+Firmware";
      license = lib.licenses.mit;
      platforms = [ "microblazeel-none" ];
      maintainer = with lib.maintainers; [ chuangzhu ];
    };
  };

  zynqmp-fsbl = mkEmbeddedswApp {
    template = "zynqmp_fsbl";
    proc = "psu_cortexa53_0";
    meta = with lib; {
      description = "Zynq MPSoC First Stage Boot Loader";
      homepage = "https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842019/FSBL";
      license = licenses.mit;
      # It does also support running on the Cortex-R5 core, but I haven't tried that yet
      platforms = [ "aarch64-none" ];
      maintainer = with maintainers; [ chuangzhu ];
    };
  };

  zynq-fsbl = mkEmbeddedswApp {
    template = "zynq_fsbl";
    proc = "ps7_cortexa9_0";
    # arm-none-eabihf-
    postPatch = ''
      substituteInPlace cmake/toolchainfiles/cortexa9_toolchain.cmake --replace-fail arm-none-eabi- ${stdenv.cc.targetPrefix}
    '';
    meta = with lib; {
      description = "Zynq-7000 First Stage Boot Loader";
      homepage = "https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/439124055/Zynq-7000+FSBL";
      license = licenses.mit;
      platforms = [ "arm-none" ];
      maintainer = with maintainers; [ chuangzhu ];
    };
  };

  versal2-plm = mkEmbeddedswApp {
    template = "versal_plm";
    proc = plmProc;
    # The PLM is freestanding firmware running on the PMC MicroBlaze with no
    # OS/libc runtime. nixpkgs' cc-wrapper otherwise injects its full userspace
    # hardening set (-fPIC, -fstack-protector-strong, -D_FORTIFY_SOURCE=3,
    # -fstack-clash-protection, ...), which the vendor/meta-xilinx `mb-gcc`
    # build never uses: PIC emits GOT-relative accesses with no GOT set up, and
    # the stack-protector prologue reads an uninitialised __stack_chk_guard in
    # every function. Disable all of it so codegen matches the vendor toolchain.
    hardeningDisable = [ "all" ];
    # The patched gcc 13 we build the PLM with doesn't know
    # -Wreturn-mismatch, so drop mkEmbeddedswApp's -Wno-error=return-mismatch
    # (it would abort on the unknown flag) and keep the rest.
    env.NIX_CFLAGS_COMPILE =
      "-Wno-error=int-conversion -Wno-error=implicit-function-declaration"
      + lib.optionalString plmUhsMode " -DUHS_MODE_ENABLE";
    postPatch = ''
      substituteInPlace cmake/toolchainfiles/microblaze-pmu_toolchain.cmake --replace-fail mb- ${stdenv.cc.targetPrefix}
      # versal_plm builds with the plm toolchain file, not the pmu one.
      substituteInPlace cmake/toolchainfiles/microblaze-plm_toolchain.cmake --replace-fail mb- ${stdenv.cc.targetPrefix}
      # SEM is disabled on the Gen2 PMC and xilsem isn't built for it, so the
      # PLM app's unconditional -lxilsem never resolves. Drop it.
      substituteInPlace lib/sw_apps/versal_plm/src/CMakeLists.txt \
        --replace-fail "collect(PROJECT_LIB_DEPS xilsem)" "# xilsem omitted: SEM disabled, not built for Gen2 PMC"
      # newlib's __libc_init_array references _init/_fini from crti.o/crtn.o,
      # which the 32-bit MicroBlaze toolchain doesn't ship. The PLM never
      # returns, so empty stubs are correct.
      #
      # The crt0 also calls register_fini(), which pulls in newlib's whole
      # at-exit machinery (atexit / __register_exitproc / __libc_fini_array /
      # the __retarget_lock_* set) that the vendor/AMD standalone build never
      # links. The PLM never exits, so override register_fini() and atexit()
      # with no-ops to drop that chain and match the vendor image.
      cat >> lib/sw_apps/versal_plm/src/common/xplm_main.c <<'EOF'

      void _init(void) { }
      void _fini(void) { }
      void register_fini(void) { }
      int atexit(void (*fn)(void)) { (void)fn; return 0; }
      void exit(int status) { (void)status; while (1) { } }
      EOF
    ''
    + lib.optionalString (!plmWithGloss) ''
      # Don't link nixpkgs' libgloss; the standalone BSP already provides
      # xil_printf/outbyte/sbrk. Matches the vendor PLM's smaller .text.
      substituteInPlace lib/sw_apps/versal_plm/src/CMakeLists.txt \
        --replace-fail "collect(PROJECT_LIB_DEPS gloss)" "# gloss omitted: BSP self-sufficient"
    '';
    meta = with lib; {
      description = "Versal AI Edge Gen 2 Platform Loader and Manager firmware";
      homepage = "https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/2037088327/Versal+Platform+Loader+and+Manager";
      license = licenses.mit;
      platforms = [ "microblazeel-none" ];
      maintainer = with maintainers; [ chuangzhu ];
    };
  };
}
