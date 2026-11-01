# SPDX-License-Identifier: MIT
#
# What `meson-purifier` builds for interactive commands: the package cache
# of a lockfile, from the nixpkgs of the toolchain package and the library
# of the nix-purifiers. `purifier` is the source of that library as this
# flake pins it; its root default.nix takes `{ lib }` and returns the
# `lib.purifier` set.
{
  lockFile,
  nixpkgs,
  purifier,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
  purifierLib = import purifier { inherit (pkgs) lib; };
in
pkgs.callPackage ./package-cache.nix { inherit lockFile purifierLib; }
