# SPDX-License-Identifier: MIT
#
# Meson and ninja of the package set, with `meson` replaced by
# meson-purifier under that name. In a project with a lockfile it runs the
# real meson with its package cache at the locked downloads, and with
# downloads turned off for `meson setup`; elsewhere it runs meson as it is.
# `meson-purifier` sits beside it, for `meson-purifier lock`.
#
# The tools a lock run uses (git, nix-prefetch-git, Mercurial and
# Subversion) come from the end of PATH, so the user's own come first.
# Interactive commands build the package cache with nix-build
# (nix/lib/interactive.nix), from the nixpkgs of this package set and the
# library of the nix-purifiers. `purifierSource` is the source of that
# library as the meson-purifier flake pins it, which the default package
# overlay passes.
{
  lib,
  runCommand,
  makeWrapper,
  meson,
  ninja,
  git,
  nix-prefetch-git,
  mercurial,
  subversion,
  path,
  cli,
  purifierSource ? throw "meson-purifier: the toolchain needs `purifierSource`, which the default package overlay of the meson-purifier flake passes",
}:
let
  wrapperArgs = lib.escapeShellArgs [
    "--set-default"
    "MESON_PURIFIER_MESON"
    "${meson}/bin/meson"
    "--set"
    "MESON_PURIFIER_NIX_LIB"
    "${../../nix/lib}"
    "--set-default"
    "MESON_PURIFIER_NIXPKGS"
    "${path}"
    "--set-default"
    "MESON_PURIFIER_LIBRARY"
    "${purifierSource}"
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath [
      ninja
      git
      nix-prefetch-git
      mercurial
      subversion
    ])
  ];
in
runCommand "meson-purifier-meson-${meson.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit meson cli; };
    meta = {
      description = "meson with its subproject downloads from a meson-purifier lockfile";
      mainProgram = "meson-purifier";
    };
  }
  ''
    mkdir -p "$out/bin"
    ln -s ${ninja}/bin/ninja "$out/bin/ninja"
    makeWrapper ${lib.getExe cli} "$out/bin/meson" --argv0 meson --add-flags meson ${wrapperArgs}
    makeWrapper ${lib.getExe cli} "$out/bin/meson-purifier" ${wrapperArgs}
  ''
