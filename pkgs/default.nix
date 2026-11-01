# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  cli = callPackage ./cli { };
in
{
  # The meson-purifier command alone.
  inherit cli;
  # meson with `meson` running through meson-purifier, ninja, and the
  # meson-purifier command beside them.
  toolchain = callPackage ./toolchain { inherit cli; };
}
