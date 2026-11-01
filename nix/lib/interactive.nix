# SPDX-License-Identifier: MIT
#
# What `meson-purifier` builds for interactive commands: the package cache
# of a lockfile, from the nixpkgs the command was built with.
{
  lockFile,
  nixpkgs,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
pkgs.callPackage ./package-cache.nix { inherit lockFile; }
