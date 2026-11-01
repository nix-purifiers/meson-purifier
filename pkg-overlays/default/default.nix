# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.meson-purifier` (`.cli`, `.toolchain`). A consumer that lists this
# flake in `projects` holds it as `meson-purifier/default`, which its
# package sets apply by default. The builder is in the library, as
# `lib.meson-purifier.buildMesonProject`.
#
# Interactive commands build the package cache with nix-build outside this
# flake, so the toolchain gets the source of the purifier library as this
# flake pins it, whose root default.nix is the library's entry point
# outside a flake.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "meson-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      meson-purifier = added.meson-purifier // {
        toolchain = added.meson-purifier.toolchain.override {
          purifierSource = closure-inputs.purifier.outPath;
        };
      };
    };
}
