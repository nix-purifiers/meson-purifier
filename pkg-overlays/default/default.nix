# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.meson-purifier` (`.cli`, `.toolchain`), and the builder
# `pkgs.buildMesonProject` (nix/lib/build-meson-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `meson-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "meson-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildMesonProject = final.callPackage ../../nix/lib/build-meson-project.nix { };
    };
}
