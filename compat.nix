{ lib, ... }:

let
  aliased = [
    [ "xlnxVersion" ]
    [ "platform" ]
    [ "sdtDir" ]
    [ "dtDir" ]
    [ "dtb" ]
    [ "bitstream" ]
    [ "fsbl" ]
    [ "pmufw" ]
    [ "plm" ]
    [ "bif" "imageName" ]
    [ "bif" "entries" ]
    [ "bif" "text" ]
    [ "bif" "file" ]
    [ "boot-bin" ]
  ];
in
{
  imports = map (
    suffix: lib.mkAliasOptionModule ([ "hardware" "zynq" ] ++ suffix) ([ "hardware" "xlnx" ] ++ suffix)
  ) aliased;
}
