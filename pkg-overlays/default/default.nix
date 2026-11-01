# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set,
# the scope `pkgs.meson-purifier` (made with lib.makeScope), which holds the
# packages of pkgs/ (`cli`, `toolchain`) and the builder `buildMesonProject`
# (nix/lib/build-meson-project.nix). A package written for callPackage
# takes the scope by name:
#
#   { meson-purifier }: (meson-purifier.buildMesonProject { ... }).packages.<name>
#
# `meson-purifier.overrideScope` replaces what the scope shares, and
# `meson-purifier.buildMesonProject.override` what the builder takes. A
# consumer that lists this flake in `projects` holds the overlay as
# `meson-purifier/default`, which its package sets apply by default.
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
      meson-purifier = added.meson-purifier.overrideScope (
        self: super: {
          toolchain = super.toolchain.override {
            purifierSource = closure-inputs.purifier.outPath;
          };
          buildMesonProject = self.callPackage ../../nix/lib/build-meson-project.nix {
            purifierLib = closure-lib.purifier;
            inherit (closure-lib.meson-purifier) readLock;
          };
        }
      );
    };
}
