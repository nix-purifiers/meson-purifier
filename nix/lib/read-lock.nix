# SPDX-License-Identifier: MIT
#
# readLock: a meson-purifier lockfile and the wrap files of the project,
# read into the lock in memory of the purifier contract:
#
#   readLock { src, lockFile ? src + "/meson-purifier.lock.json" }
#   => {
#     purifier = "meson-purifier";
#     entries  = [ ... ];  # library entries, at their package cache paths
#     outputs  = { <target> = { type; files; }; };
#     problems = [ ... ];  # each names `meson-purifier lock`
#     meson    = { subprojectsDir; setupArgs; files; installedWraps;
#                  definitionFresh; };
#   }
#
# `checkLock` of the purifier library fails evaluation with the problems.
# The other attributes are read only after that check.
#
# The entries come from two places. The lockfile records the git, hg and
# svn checkouts, the archives of wraps that a download or a patch directory
# carries, and the wraps Meson installs from wrapdb.json, with their
# archives. A [wrap-file] wrap in the subproject directory of `src` names
# its archives with URLs and SHA-256 hashes itself, so the lockfile lists
# only its name in `wrapFiles`, and this file reads the archives from it
# (wrap-file.nix).
#
# Reading wrap files needs a `src` that is available at evaluation: a
# path, a flake input, or the result of builtins.fetchTarball or
# builtins.fetchGit. A `src` that a derivation builds, such as
# fetchFromGitHub, would need import-from-derivation; a lockfile for such a
# source is written with `meson-purifier lock --record-all`, which records
# the archives of every wrap.
#
# The entries lie at their paths in the package cache: `cache/<name>` for
# what Meson reads from MESON_PACKAGE_CACHE_DIR, and
# `wrapdb-wraps/<name>` for the wraps Meson would install.
{ lib }:
{
  src,
  lockFile ? src + "/meson-purifier.lock.json",
}:
let
  name = toString lockFile;
  relock = "Run `meson-purifier lock` to write it again.";

  # A path, or a store path as a string with its context, which `+` and
  # readFile take.
  source = if builtins.isPath src then src else toString src;
  # A string whose context names a derivation output is built, not read.
  available =
    builtins.isPath src
    || builtins.all (item: !(item ? outputs)) (
      builtins.attrValues (builtins.getContext (toString src))
    );

  text = builtins.readFile lockFile;
  lines = builtins.filter builtins.isString (builtins.split "\n" text);
  conflicted = builtins.any (
    line: builtins.match "(<<<<<<<|=======|>>>>>>>)([ ].*)?" line != null
  ) lines;
  # The first line with content opens the object. A pattern over the whole
  # text would need `(.|\n)*`, which the regular expressions of Nix match by
  # recursion, one level per character.
  contentLines = builtins.filter (line: builtins.match "[[:space:]]*" line == null) lines;
  object = contentLines != [ ] && builtins.match "[[:space:]]*\\{.*" (lib.head contentLines) != null;

  lock = builtins.fromJSON text;
  supportedVersion = import ./lock-version.nix;

  fields = [
    "subprojectsDir"
    "wrapsHash"
    "definitionHash"
    "setupArgs"
    "outputs"
    "installedWraps"
    "wrapFiles"
    "artifacts"
    "contentHash"
  ];
  missingFields = builtins.filter (field: !(lock ? ${field})) fields;

  # The hash of the content of the lockfile without `contentHash`, as
  # compact JSON with sorted keys; `meson-purifier lock` records it with the
  # same rule (content_hash in pkgs/cli/meson_purifier.py).
  contentHash = builtins.hashString "sha256" (
    builtins.toJSON (builtins.removeAttrs lock [ "contentHash" ])
  );

  # Every path names one entry of Meson's package cache or one wrap file, so
  # it is a single file name.
  singleName = path: builtins.match "[^/]+" path != null && path != "." && path != "..";

  entryProblem =
    entry:
    if !(builtins.isAttrs entry && builtins.isString (entry.path or null) && singleName entry.path) then
      "${name} has the entry ${builtins.toJSON entry}, whose path is not a single file name. ${relock}"
    else if
      builtins.length (
        builtins.filter (kind: entry ? ${kind}) [
          "url"
          "git"
          "hg"
          "svn"
        ]
      ) != 1
      || !(entry ? hash)
    then
      "${name} has an entry for ${entry.path} without exactly one url, git, hg or svn source and a hash. ${relock}"
    else if entry ? url && !builtins.isList (entry.mirrors or null) then
      "${name} has an entry for ${entry.path} without a `mirrors` list. ${relock}"
    else
      null;

  wrapFileProblem =
    file:
    if builtins.isString file && singleName file && lib.hasSuffix ".wrap" file then
      null
    else
      "${name} lists ${builtins.toJSON file} in wrapFiles, which is not the name of a wrap file. ${relock}";

  hashes = import ./inputs-hash.nix {
    project = source;
    inherit (lock) subprojectsDir;
    installed = map (entry: entry.path) lock.installedWraps;
  };

  contentProblems =
    builtins.filter (problem: problem != null) (
      map entryProblem (lock.artifacts ++ lock.installedWraps) ++ map wrapFileProblem lock.wrapFiles
    )
    ++
      lib.optional (!available && lock.wrapFiles != [ ])
        "${name} reads the archives of ${toString (builtins.length lock.wrapFiles)} wrap files from the source, which a derivation builds, so Nix cannot read them at evaluation. Run `meson-purifier lock --record-all`, which records them in the lockfile, or take the source from a flake input or builtins.fetchTarball."
    ++
      lib.optional (available && hashes.wraps != lock.wrapsHash)
        "the wrap files of ${toString src} changed since ${name} was written, so it may lack a download. Run `meson-purifier lock`.";

  problems =
    if conflicted then
      [ "${name} has merge conflict markers. ${relock}" ]
    else if !object then
      [ "${name} is not a JSON object. ${relock}" ]
    else if lock.version or null != supportedVersion then
      [
        "${name} has lock format version ${
          builtins.toJSON (lock.version or null)
        }; this library reads version ${toString supportedVersion}. Run `meson-purifier lock` with the meson-purifier revision of this library."
      ]
    else if missingFields != [ ] then
      [ "${name} lacks ${builtins.concatStringsSep ", " missingFields}. ${relock}" ]
    else if contentHash != lock.contentHash then
      [
        "${name} differs from what `meson-purifier lock` wrote (its contentHash does not match): it was edited by hand. ${relock}"
      ]
    else
      contentProblems;

  wrapFile = import ./wrap-file.nix { inherit lib; };
  derived = builtins.concatMap (
    file: wrapFile file (builtins.readFile (source + "/${lock.subprojectsDir}/${file}"))
  ) lock.wrapFiles;

  under = directory: entry: entry // { path = "${directory}/${entry.path}"; };

  # checkLock looks at the shape of `entries` and `outputs` before it
  # reports the problems, so both stay empty for a lockfile with problems,
  # which may not even be JSON.
  usable = problems == [ ];
in
{
  purifier = "meson-purifier";
  inherit problems;
  entries =
    if usable then
      map (under "cache") (derived ++ lock.artifacts) ++ map (under "wrapdb-wraps") lock.installedWraps
    else
      [ ];
  outputs = if usable then lock.outputs.targets else { };
  meson = {
    inherit (lock) subprojectsDir setupArgs installedWraps;
    inherit (lock.outputs) files;
    # A build definition that changed since the lock run leaves the
    # downloads alone; only the outputs may be out of date, which the
    # builder reports as a warning.
    definitionFresh = !available || hashes.definition == lock.definitionHash;
  };
}
