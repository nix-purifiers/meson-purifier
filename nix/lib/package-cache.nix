# SPDX-License-Identifier: MIT
#
# The package cache of a lockfile, for Meson's MESON_PACKAGE_CACHE_DIR, as
# a tree of the shared library of the nix-purifiers (`purifierLib.tree`).
#
# The result has two directories:
#
#   cache/          what Meson reads as its package cache. A wrap-file's
#                   source and patch archives are files named by their
#                   source_filename and patch_filename, which Meson checks
#                   against the wrap's hashes. A wrap-git, wrap-hg or
#                   wrap-svn checkout is a directory named by the wrap's
#                   `directory`, which Meson copies into the subproject
#                   directory instead of checking the source out.
#   wrapdb-wraps/   the wrap files Meson would install from
#                   subprojects/wrapdb.json while it configures the project.
#
# The file is a package for callPackage, which passes `lockFile` and
# `purifierLib` with the package set.
{
  pkgs,
  purifierLib,
  lockFile,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  under = directory: entry: entry // { path = "${directory}/${entry.path}"; };
  tree = purifierLib.tree {
    inherit pkgs;
    name = "meson-purifier-package-cache";
    entries = map (under "cache") lock.artifacts ++ map (under "wrapdb-wraps") lock.installedWraps;
  };
in
tree.overrideAttrs (old: {
  passthru = old.passthru or { } // {
    inherit lock;
  };
})
