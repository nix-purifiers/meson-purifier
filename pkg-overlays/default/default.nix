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
# Both build the package cache with `lib.meson-purifier.packageCache`.
# Interactive commands build it outside a Nix build, through this flake, so
# the toolchain gets the locked reference of this flake's source.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "meson-purifier";
  root = closure-lib.caisson-core.libManifest.root;
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
          flakeRef = "path:${root.outPath}" + (if root ? narHash then "?narHash=${root.narHash}" else "");
        };
      };
      buildMesonProject = final.callPackage ../../nix/lib/build-meson-project.nix {
        packageCacheOf = closure-lib.meson-purifier.packageCache;
      };
    };
}
