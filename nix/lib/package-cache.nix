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
# `packages` are the fetchers and the packages that tree and fetchEntry
# take by name: fetchurl, fetchgit, fetchhg, fetchsvn, runCommand, unzip,
# zstd, python3 and writeText, with the fetchers a user passes to the
# builder in place of nixpkgs' own.
{
  purifierLib,
  entries,
  packages,
}:
purifierLib.tree (
  packages
  // {
    inherit entries;
    name = "meson-purifier-package-cache";
  }
)
