# SPDX-License-Identifier: MIT
#
# Reads a meson-purifier lockfile (written by `meson-purifier lock`).
#
# Needs no nixpkgs. `lockFile` is a path, or an absolute path as a string.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a package cache path. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_", and a long name keeps
  # its end. `meson-purifier lock` names its downloads with the same rule
  # (store_name in pkgs/cli/meson_purifier.py), so the lock run and the
  # builds share store paths.
  storeName =
    path:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" path)
      );
      length = builtins.stringLength replaced;
      tail = if length > 200 then builtins.substring (length - 200) 200 replaced else replaced;
      undotted = builtins.head (builtins.match "\\.*(.*)" tail);
    in
    if undotted == "" then "file" else undotted;

  # Every path names one entry of Meson's package cache or one wrap file, so
  # it is a single file name.
  checkPath =
    entry:
    builtins.match "[^/]+" entry.path != null && entry.path != "." && entry.path != ".."
    || throw "meson-purifier: ${toString lockFile} has the path ${builtins.toJSON entry.path}, which is not a single file name";

  # A file entry lists its fallback URLs in `mirrors`, an empty list when
  # there are none.
  checkMirrors =
    entry:
    !(entry ? url)
    || builtins.isList (entry.mirrors or null)
    || throw "meson-purifier: ${toString lockFile} has an entry for ${entry.path} without a `mirrors` list. Run `meson-purifier lock`.";

  # Every entry has exactly one source: a URL, or a git, hg or svn checkout.
  checkKind =
    entry:
    builtins.length (
      builtins.filter (kind: entry ? ${kind}) [
        "url"
        "git"
        "hg"
        "svn"
      ]
    ) == 1
    && entry ? hash
    || throw "meson-purifier: ${toString lockFile} has an entry for ${
      builtins.toJSON (entry.path or null)
    } without exactly one url, git, hg or svn source and a hash. Run `meson-purifier lock` to write it again.";

  fields = [
    "subprojectsDir"
    "wrapsHash"
    "definitionHash"
    "setupArgs"
    "outputs"
    "installedWraps"
    "artifacts"
  ];
  missingFields = builtins.filter (field: !(lock ? ${field})) fields;
in
assert
  lock.version or null == supportedVersion
  || throw "meson-purifier: ${toString lockFile} has lock format version ${
    builtins.toJSON (lock.version or null)
  }; this library reads version ${toString supportedVersion}. Run `meson-purifier lock` with the meson-purifier revision of this library.";
assert
  missingFields == [ ]
  || throw "meson-purifier: ${toString lockFile} lacks ${builtins.concatStringsSep ", " missingFields}. Run `meson-purifier lock` to write it again.";
assert builtins.all (entry: checkPath entry && checkKind entry && checkMirrors entry) (
  lock.artifacts ++ lock.installedWraps
);
lock
// {
  inherit storeName;
}
