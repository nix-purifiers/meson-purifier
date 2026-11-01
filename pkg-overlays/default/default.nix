# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.meson-purifier` (`.cli`, `.toolchain`), and the builder
# `pkgs.buildMesonProject` (nix/lib/build-meson-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `meson-purifier/default`, which its package sets
# apply by default.
#
# The builder takes the purifier library and readLock from the library of
# this flake. Interactive commands build the package cache with nix-build
# outside this flake, so the toolchain gets the source of the purifier
# library as this flake pins it; outside a flake, the root default.nix of
# that source returns the library.
{
  closure-lib,
  closure-inputs,
  ...
}:
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
      buildMesonProject = final.callPackage ../../nix/lib/build-meson-project.nix {
        purifierLib = closure-lib.purifier;
        inherit (closure-lib.meson-purifier) readLock;
      };
    };
}
