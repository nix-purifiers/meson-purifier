# SPDX-License-Identifier: MIT
#
# What `meson-purifier` builds for interactive commands: the package cache
# of a lockfile, from the nixpkgs of the toolchain package and the library
# of the nix-purifiers. `purifier` is the source of that library as this
# flake pins it; its root default.nix takes `{ lib }` and returns the
# `lib.purifier` set. `projectDir` is the absolute path of the project,
# whose wrap files name some of the downloads.
{
  lockFile,
  projectDir,
  nixpkgs,
  purifier,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
  purifierLib = import purifier { inherit (pkgs) lib; };
  readLock = import ../../lib-overlays/default/read-lock.nix { inherit (pkgs) lib; };
  lock = readLock {
    # A path, not a string: readLock reads wrap files from it without
    # copying the project to the store.
    src = /. + projectDir;
    inherit lockFile;
  };
in
import ../build-meson-project/package-cache.nix {
  inherit purifierLib;
  entries = purifierLib.entriesFor system lock;
  packages = {
    inherit (pkgs)
      fetchurl
      fetchgit
      fetchhg
      fetchsvn
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  };
}
