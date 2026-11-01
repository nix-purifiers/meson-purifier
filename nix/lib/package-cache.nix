# SPDX-License-Identifier: MIT
#
# The package cache of a lock, for Meson's MESON_PACKAGE_CACHE_DIR, as a
# tree of the shared library of the nix-purifiers (`purifierLib.tree`).
# `entries` are the entries of the lock for one system, which readLock
# (read-lock.nix) places at these paths:
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
# The file is a package for callPackage. `fetchers` replaces nixpkgs'
# fetchers in the library's fetchEntry, for mirrors or credentials.
{
  pkgs,
  purifierLib,
  entries,
  fetchers ? { },
}:
purifierLib.tree (
  fetchers
  // {
    inherit pkgs entries;
    name = "meson-purifier-package-cache";
  }
)
