{
  lib,
  qemu,
  fetchFromGitHub,
  fetchgit,
  libgcrypt,
  xlnxVersion ? "2025.1",
}:

# AMD's downstream QEMU fork. Adds the `arm-generic-fdt` machine and the
# Versal/Versal2 device models driven by hardware DTBs from the sibling
# `qemu-devicetrees` repo. Used by `scripts/qemu-versal2-xlnx.sh`.
#
# The fork is based on QEMU 8.2.7. nixpkgs ships QEMU 10.x, so the
# `patches` and version-specific `postPatch` from the nixpkgs derivation
# don't apply here — we drop them.
#
# We don't use `fetchSubmodules = true` because `roms/edk2` recurses
# into unauthenticated GitHub submodules that fail in the Nix sandbox.
# The only meson subproject the build actually needs (keycodemapdb, for
# UI keymap generation) is fetched separately below; the rest of the
# subprojects are guarded behind features we don't enable.

let
  # The only meson subproject the build actually needs (UI keymap
  # generation). Revision taken from subprojects/keycodemapdb.wrap.
  # We pre-fetch it because meson would otherwise `git clone` it
  # during configure, which the Nix sandbox can't do.
  keycodemapdb = fetchgit {
    url = "https://gitlab.com/qemu-project/keycodemapdb.git";
    rev = "f5772a62ec52591ff6870b7e8ef32482371f22c6";
    hash = "sha256-EQrnBAXQhllbVCHpOsgREzYGncMUPEIoWFGnjo+hrH4=";
  };
in

qemu.overrideAttrs (old: {
  pname = "qemu-xlnx";
  version = "8.2.7-xilinx-v${xlnxVersion}";

  # The fork's crypto/ecdsa-stub.c includes <gcrypt.h> even in stub form,
  # and the Versal2 ASU RSA helpers (hw/misc/ipcores-rsa5-4k.c) use
  # libgcrypt for the underlying big-number ops. Nixpkgs' QEMU 10
  # derivation doesn't need it, so we add it here.
  buildInputs = old.buildInputs ++ [ libgcrypt ];

  # Force gcrypt as the crypto backend. By default meson prefers
  # gnutls's built-in crypto when available, leaving gcrypt unfound —
  # which then causes the XLNX RSA helpers to be skipped at compile time.
  configureFlags = old.configureFlags ++ [ "--enable-gcrypt" ];

  src = fetchFromGitHub {
    owner = "Xilinx";
    repo = "qemu";
    rev = "xilinx_v${xlnxVersion}";
    hash =
      {
        "2024.1" = lib.fakeHash;
        "2025.1" = "sha256-c4HcrUydXsiX2iVWL3g9X0LujaP0JHZdV9R1F/34ASs=";
      }
      .${xlnxVersion};
    # We deliberately skip submodules:
    #   * roms/* are firmware blobs we don't need (we boot via -device loader).
    #   * roms/edk2 has nested submodules requiring GitHub credentials.
    # Meson subprojects (keycodemapdb, dtc, slirp, …) are populated below
    # in preConfigure via per-subproject fixed-output derivations.
    fetchSubmodules = false;
  };

  # nixpkgs' patches assume QEMU 10 line numbers / source layout.
  patches = [ ];

  # nixpkgs' postPatch removes a line from qga/meson.build that may not
  # exist (or be on a different line) in 8.2. Skip it; if QGA fails to
  # build we disable it via configureFlags instead.
  postPatch = ''
    # qga/meson.build installs an empty /var/run unconditionally, which
    # the Nix sandbox can't write. (Upstream nixpkgs qemu does the same
    # patch; we have to repeat it because we cleared its postPatch.)
    sed -i "/install_emptydir(get_option('localstatedir') \/ 'run')/d" \
        qga/meson.build

    # Pre-populate the keycodemapdb meson subproject (meson would
    # otherwise `git clone` it during configure).
    mkdir -p subprojects/keycodemapdb
    cp -r ${keycodemapdb}/* subprojects/keycodemapdb/
    chmod -R +w subprojects/keycodemapdb

    # Drop tests/fp/, the only other consumer of meson subprojects in
    # this build. It needs berkeley-softfloat-3 / berkeley-testfloat-3
    # only for floating-point unit tests we don't run.
    substituteInPlace tests/meson.build \
      --replace-fail "subdir('fp')" "# subdir('fp')  # disabled in qemu-xlnx"

    # The fork's hw/misc/xlnx-versal2-asu-ecdsa-rsa.c #includes
    # xlnx-versal-ecdsa-rsa.c, which calls rsa_do_*/csu_rsa* helpers
    # defined in ipcores-rsa5-4k.c and csu_rsa5_4k.c. Those two files
    # are only compiled when CONFIG_XLNX_ZYNQMP_CSU is enabled — which
    # CONFIG_XLNX_VERSAL doesn't pull in, causing unresolved symbols at
    # link time. Make XLNX_VERSAL select XLNX_ZYNQMP_CSU so the RSA
    # helpers are built alongside the Versal2 ASU model.
    substituteInPlace hw/arm/Kconfig \
      --replace-fail \
        "select XLNX_CSU_DMA" \
        "select XLNX_CSU_DMA"$'\n'"    select XLNX_ZYNQMP_CSU"

    # The fork's meson.build looks for libgcrypt via `config-tool`
    # (i.e. libgcrypt-config on PATH). nixpkgs puts libgcrypt-config in
    # the dev output's bin/ which isn't on PATH at build time, but
    # libgcrypt.pc *is* on PKG_CONFIG_PATH. Switch the detection method.
    substituteInPlace meson.build \
      --replace-fail \
        "dependency('libgcrypt', version: '>=1.8'," \
        "dependency('libgcrypt', version: '>=1.8', method: 'pkg-config',"
    substituteInPlace meson.build \
      --replace-fail \
        "                        method: 'config-tool'," \
        "                        # method: 'config-tool',  # see qemu-xlnx.nix"
  '';

  meta = old.meta // {
    description = "AMD's downstream QEMU fork with Versal/Zynq machine models";
    homepage = "https://github.com/Xilinx/qemu";
  };
})
