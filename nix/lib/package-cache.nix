# SPDX-License-Identifier: MIT
#
# The package cache of a lockfile, for Meson's MESON_PACKAGE_CACHE_DIR.
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
# The file is a package for callPackage, which passes `lockFile` with the
# fetchers.
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  lockFile,
}:
let
  lock = import ./lock.nix { inherit lockFile; };

  fetch =
    entry:
    if entry ? url then
      fetchurl {
        name = lock.storeName entry.path;
        # `mirrors` are the wrap's source_fallback_url or
        # patch_fallback_url, which serve the same bytes.
        urls = [ entry.url ] ++ entry.mirrors;
        inherit (entry) hash;
      }
    else if entry ? git then
      # meson-purifier writes every git entry with leaveDotGit = false and
      # commitObject = null.
      assert
        !entry.git.leaveDotGit
        || throw "meson-purifier: ${toString lockFile} has a git entry for ${entry.path} with leaveDotGit, which meson-purifier does not write";
      fetchgit {
        inherit (entry.git) url rev leaveDotGit;
        fetchSubmodules = entry.git.submodules;
        inherit (entry) hash;
      }
    else if entry ? hg then
      fetchhg {
        inherit (entry.hg) url rev;
        fetchSubrepos = entry.hg.subrepos;
        inherit (entry) hash;
      }
    else if entry ? svn then
      fetchsvn {
        inherit (entry.svn)
          url
          rev
          ignoreExternals
          ignoreKeywords
          ;
        inherit (entry) hash;
      }
    else
      throw "meson-purifier: ${toString lockFile} has an entry for ${entry.path} with no url, git, hg or svn source";

  link = directory: entry: ''
    ln -s ${fetch entry} "$out"/${directory}/${lib.escapeShellArg entry.path}
  '';
in
runCommand "meson-purifier-package-cache"
  {
    passthru = { inherit lock; };
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p "$out/cache" "$out/wrapdb-wraps"
    ${lib.concatMapStrings (link "cache") lock.artifacts}
    ${lib.concatMapStrings (link "wrapdb-wraps") lock.installedWraps}
  ''
