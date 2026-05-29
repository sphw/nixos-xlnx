# Overlay: swap nixpkgs' stock MicroBlaze bare-metal cross toolchain for AMD's
# patched one, so boot firmware (Versal PLM, ZynqMP PMUFW) built from the
# embeddedsw source compiles with the codegen AMD actually ships.
#
# nixpkgs builds the microblaze cross set with vanilla gcc 14 / binutils 2.44 /
# newlib 4.5. AMD (meta-xilinx → meta-microblaze) builds gcc 13 + a large
# MicroBlaze backend patch set, newlib + 11 patches (notably deleting
# libgloss's xil_printf and using a port-specific sbrk), and configures newlib
# --disable-newlib-reent-check-verify. The unpatched compiler miscompiles the
# 32-bit MicroBlaze PLM (it hangs a few characters into its banner); these are
# the patches that make AMD's from-source PLM work.
#
# This is a plain *overlay*, not a crossOverlay. nixpkgs builds the cross
# compiler in the "build tool packages" stage of pkgs/stdenv/cross/default.nix,
# and that stage is given `overlays` only (crossOverlays reach just the final
# target stage). The body is guarded on `targetPlatform.isMicroBlaze`, so the
# native aarch64 toolchain is untouched — only the microblaze cross stages that
# build the PLM see these overrides.

final: prev:

let
  inherit (prev) lib;

  # Pinned to rel-v2025.2 HEAD, matching the embeddedsw xilinx_v2025.2 the PLM
  # is built from (pkgs/embeddedsw.nix). meta-xilinx tracks GNU upstream sources
  # + patch files, so we just reference the patch directories.
  metaXilinx = prev.fetchFromGitHub {
    owner = "Xilinx";
    repo = "meta-xilinx";
    rev = "658a3a888dceec7e2d30f32166fc009f4f91f294";
    hash = "sha256-Vy/SS+8s7GiPApWeAIVSBJvMRgyw3VSgEFPcxEhesRE=";
  };

  gccDir = metaXilinx + "/meta-microblaze/recipes-devtools/gcc/gcc-13";
  newlibDir = "${metaXilinx}/meta-microblaze/recipes-core/newlib/files";
  binutilsDir = "${metaXilinx}/meta-microblaze/recipes-devtools/binutils/binutils";

  # All 11 MicroBlaze newlib patches, in SRC_URI order (microblaze-newlib.inc).
  # They apply against upstream newlib's libgloss/microblaze (Xilinx upstreamed
  # the MB port). 0003/0004 delete libgloss's xil_printf — the duplicate that
  # collided with the standalone BSP's own xil_printf and forced us to drop
  # -lgloss; removing it lets us link libgloss (for its syscall stubs) again.
  # 0011 wires a port-specific sbrk.
  newlibPatches = map (n: "${newlibDir}/${n}") [
    "0001-Patch-microblaze-Modified-_exceptional_handler.patch"
    "0002-LOCAL-Add-missing-declarations-for-xil_printf-to-std.patch"
    "0003-Local-deleting-the-xil_printf.c-file-as-now-it-part-.patch"
    "0004-Local-deleting-the-xil_printf.o-from-MAKEFILE.patch"
    "0005-MB-X-intial-commit.patch"
    "0006-Patch-Microblaze-newlib-port-for-microblaze-m64-flag.patch"
    "0007-fixing-the-bug-in-crt-files-added-addlik-instead-of-.patch"
    "0008-Patch-MicroBlaze-Added-MB-64-support-to-strcmp-strcp.patch"
    "0009-Patch-MicroBlaze-Removing-the-Assembly-implementatio.patch"
    "0010-Fixed-the-bug-in-crtinit.s-for-MB-64.patch"
    "0011-Use-port-specific-sbrk.patch"
  ];

  # MicroBlaze gcc backend patches. We apply AMD's *complete* set (0008-0056 +
  # the OE multilib hack, in SRC_URI/numeric order) — the same codegen that
  # builds AMD's working PLM — and skip only the testsuite-only patches
  # (0001-0007: gcc/testsuite/*, never built here).
  #
  # The full set is required, not just the obvious 32-bit-only patches: the PLM
  # is built with -flto (microblaze-plm_toolchain.cmake), and several fixes that
  # matter for the 32-bit LTO build are numbered in the "MB-64" range — notably
  # 0039 (32-bit LTO codegen), 0050 (disable -fivopts, which miscompiles MB
  # loops), 0049 (freg struct-return crash), 0052/0054/0040. A 32-bit-only
  # cherry-pick (which left these out) compiled but still hung at the first
  # %s-formatted print (strlen + a tight output loop), i.e. an LTO/loop-opt
  # miscompile. The MB-64 instruction patterns are gated behind m64/TARGET_MB_64
  # so they don't perturb the default 32-bit codegen, and nixpkgs builds this
  # cross gcc with multilib disabled (`-print-multi-lib` = `.;`), so the m64
  # MULTILIB options never trigger a 64-bit libgcc build and the multilib hack
  # is inert. All 49 patches + hack apply cleanly, in order, to gcc 13.4.0.
  isTestsuitePatch =
    p: lib.any (n: lib.hasPrefix n (baseNameOf p)) [
      "0001-" "0002-" "0003-" "0004-" "0005-" "0006-" "0007-"
    ];
  gccPatches = builtins.filter (p: lib.hasSuffix ".patch" p && !isTestsuitePatch p) (
    builtins.sort (a: b: a < b) (map toString (lib.filesystem.listFilesRecursive gccDir))
  );

in
lib.optionalAttrs prev.stdenv.targetPlatform.isMicroBlaze {
  # newlib + the 11 MicroBlaze patches and AMD's configure flag. Pinned to
  # 4.4.0.20231231 — the version OE scarthgap (which meta-xilinx rel-v2025.2
  # targets, LAYERSERIES_COMPAT_xilinx = "scarthgap") ships, so the patches
  # apply as authored. nixpkgs' 4.5.0 restructured libgloss from recursive
  # Makefile.in to flat Makefile.inc, which the patches (0004/0011) don't match.
  # We drop nixpkgs' mips-only libgloss patch (irrelevant to microblaze) and
  # swap --enable-newlib-reent-check-verify for AMD's --disable. These are the
  # newlib *source* changes; the compiler that actually emits newlib's object
  # code is overridden separately (see gccWithoutTargetLibc below) — its codegen
  # matters just as much as the final cross gcc's, because newlib's compiled
  # str*/mem* routines are linked straight into the PLM.
  newlib = prev.newlib.overrideAttrs (o: {
    version = "4.4.0.20231231";
    src = prev.fetchurl {
      url = "ftp://sourceware.org/pub/newlib/newlib-4.4.0.20231231.tar.gz";
      hash = "sha256-DBZqOeG/CVHfr81olJ/g5LbTZYCB1igvOa7vxjEPLxM=";
    };
    patches = newlibPatches;
    configureFlags =
      (lib.remove "--enable-newlib-reent-check-verify" o.configureFlags)
      ++ [ "--disable-newlib-reent-check-verify" ];
    # newlib is built by the gcc-14 static stage (gccWithoutTargetLibc); gcc 14
    # promotes implicit-function-declaration etc. to errors, which trips
    # libgloss's "tiny linux BSP" files (linux-outbyte.c calls _write, etc.).
    # gcc 13 (what AMD uses) only warns — demote to match, as the rest of this
    # repo does for gcc-14-built Xilinx sources.
    env = (o.env or { }) // {
      NIX_CFLAGS_COMPILE = toString [
        (o.env.NIX_CFLAGS_COMPILE or "")
        "-Wno-error=implicit-function-declaration"
        "-Wno-error=int-conversion"
        "-Wno-error=implicit-int"
      ];
    };
  });

  # The compiler that builds newlib (above). newlib is compiled by
  # `stdenvNoLibc` -> `gccCrossLibcStdenv` -> `buildPackages.gccWithoutTargetLibc`,
  # which nixpkgs pins to `default-gcc-version` (gcc 14) and which gets NONE of
  # the MicroBlaze backend patches below. The result: newlib's object code
  # (notably libc/machine/microblaze/strlen.c + the mem*/str* routines) is
  # emitted by the *unpatched* gcc 14 and linked into the PLM — the PLM then
  # hangs a few characters into its banner at the first %s print (strlen + a
  # tight output loop), exactly the miscompile this overlay exists to avoid.
  # (Confirmed via DWARF DW_AT_producer: 8 newlib TUs came out "GNU C17 14.3.0".)
  # Rebuild gccWithoutTargetLibc on the same patched gcc 13.4.0 as the final
  # compiler: reuse its existing gccFun args, swap the version 14 -> 13, add the
  # backend patches, and re-wrap with the no-libc bintools.
  gccWithoutTargetLibc = prev.wrapCCWith {
    cc = (prev.gccWithoutTargetLibc.cc.override {
      majorMinorVersion = "13";
    }).overrideAttrs (o: {
      patches = (o.patches or [ ]) ++ gccPatches;
    });
    bintools = final.binutilsNoLibc;
    libc = final.binutilsNoLibc.libc;
    extraPackages = [ ];
  };

  # binutils + AMD's MicroBlaze patch set, built from the *exact* tree AMD/poky
  # use: the sourceware binutils-gdb git at branch binutils-2_42-branch, SRCREV
  # f9488b0 (what poky scarthgap pins). This matters because the patches add a
  # 64-bit MicroBlaze BFD backend (elf64-microblaze.c) wired to that tree's bfd
  # internals — it does NOT compile against GNU's 2.42 or 2.44 *release*
  # tarballs (verify_endian_match / elf_dyn_relocs / link_hash_table_init all
  # differ). Since the tree is the full binutils-gdb checkout, gdb is present,
  # so the patches apply unmodified (in SRC_URI/numeric order); we then build
  # binutils only (--disable-gdb/sim). Overriding the *unwrapped* package reaches
  # every wrapper (binutils, binutilsNoLibc), so the cross gcc, newlib and the
  # PLM link all use the patched as/ld. nixpkgs' own binutils patches target
  # 2.44 and don't apply to the 2.42 branch, so we drop them — deterministic
  # archives stay on via configureFlags and a bare-metal cross needs no rpath
  # search.
  binutils-unwrapped = (prev.binutils-unwrapped.override { enableGold = false; }).overrideAttrs (o: {
    version = "2.42";
    src = prev.fetchgit {
      url = "https://sourceware.org/git/binutils-gdb.git";
      rev = "f9488b0d92b591bdf3ff8cce485cb0e1b3727cc0";
      hash = "sha256-dhWsvTNyJr0tgPmnfPiNV01u8fXE0jMAyH3philfPGo=";
    };
    patches = [ ];
    # A git checkout (unlike the release tarball) ships no generated lexers /
    # parsers, so the build regenerates syslex.c / *parse.c — needs flex+bison.
    nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [
      prev.buildPackages.flex
      prev.buildPackages.bison
    ];
    configureFlags = (o.configureFlags or [ ]) ++ [
      "--disable-gdb"
      "--disable-gdbserver"
      "--disable-sim"
    ];
    # AMD's added elf64-microblaze.c uses the older bfd API (verify_endian_match
    # / elf_dyn_relocs signatures) and compiles fine under the older host gcc
    # AMD uses, but nixpkgs builds binutils with gcc 14, which promotes
    # incompatible-pointer-types/int-conversion to hard errors. --disable-werror
    # doesn't cover gcc's own default promotions. Demote them (we don't run the
    # 64-bit MB backend anyway — only the 32-bit PLM).
    env = o.env // {
      NIX_CFLAGS_COMPILE = (o.env.NIX_CFLAGS_COMPILE or "")
        + " -Wno-error=incompatible-pointer-types -Wno-error=int-conversion"
        + " -Wno-error=implicit-function-declaration -Wno-error=implicit-int";
    };
    postPatch = (o.postPatch or "") + ''
      echo "applying MicroBlaze binutils patches..."
      for _src in ${binutilsDir}/*.patch; do
        echo "  $(basename "$_src")"
        patch -p1 < "$_src"
      done
    '';
  });

  # Re-wrap nixpkgs' cross gcc 13 (13.4.0 — a bugfix release over AMD's 13.3.0;
  # the substance is the MicroBlaze backend patches, which target the stable
  # microblaze/ backend files and apply to either) with the MB backend patch
  # set. prev.wrapCC reuses the cross bintools + (patched) newlib exactly the
  # way gcc14 was wrapped, so only the compiler version + codegen change. In the
  # microblaze cross set this becomes buildPackages.gcc — i.e. the compiler that
  # actually builds the PLM (and supplies libgcc).
  gcc = prev.wrapCC (final.gcc13.cc.overrideAttrs (o: {
    patches = (o.patches or [ ]) ++ gccPatches;
  }));
}
