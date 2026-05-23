{
  lib,
  runCommand,
  dtc,
  qemu,
  qemu-devicetrees-xlnx,
}:

# Build-time software-DTB constructor for the Versal2 QEMU paths.
#
# Real silicon receives its DTB from BL31's handoff, driven by the PMC's
# PLM. Under QEMU we hand the kernel a software DTB at `0x50000000` via
# `-device loader`; that DTB needs `/chosen/bootargs` baked in so U-Boot
# can propagate the kernel cmdline.
#
# Baking `/chosen/bootargs` into a derivation (rather than a runtime
# `fdtput`) keeps the artifact reproducible and cacheable.

{
  # Software DTB for the upstream `amd-versal2-virt` machine.
  #
  # Dumps QEMU's own emulated DTB (via `-machine ...,dumpdtb=...`) at
  # build time, then bakes in `/chosen/bootargs`.
  #
  # `bootargs` is the full kernel cmdline string (including
  # `init=/nix/store/.../init`).
  dumpedDtb =
    { bootargs }:
    runCommand "versal2-qemu-swdtb-dumped" {
      nativeBuildInputs = [
        dtc
        qemu
      ];
      inherit bootargs;
    } ''
      mkdir -p $TMPDIR/run
      # qemu-system-aarch64 expects a writable HOME for caches; the
      # nix sandbox provides one but is read-only outside $TMPDIR.
      HOME=$TMPDIR \
        qemu-system-aarch64 \
          -M "amd-versal2-virt,dumpdtb=$out" \
          -display none > /dev/null

      fdtput -c $out /chosen 2>/dev/null || true
      fdtput -ts $out /chosen bootargs "$bootargs"
    '';

  # Software DTB for AMD's downstream QEMU fork (`arm-generic-fdt`).
  #
  # Copies one of the `board-versal2-*.dtb` files shipped by
  # `qemu-devicetrees-xlnx` and bakes in `/chosen/bootargs`.
  #
  # Pass the relative path within `qemu-devicetrees-xlnx` (default
  # `SINGLE_ARCH/board-versal2-psxc-vek385.dtb`) via `hwDtb`.
  hwDtb =
    {
      bootargs,
      hwDtb ? "SINGLE_ARCH/board-versal2-psxc-vek385.dtb",
    }:
    runCommand "versal2-qemu-swdtb-${baseNameOf hwDtb}" {
      nativeBuildInputs = [ dtc ];
      inherit bootargs;
    } ''
      cp ${qemu-devicetrees-xlnx}/${hwDtb} $out
      chmod +w $out
      fdtput -c $out /chosen 2>/dev/null || true
      fdtput -ts $out /chosen bootargs "$bootargs"
    '';
}
