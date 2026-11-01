# SPDX-License-Identifier: MIT
#
# buildMesonProject: the sandboxed build of a Meson project, from the
# lockfile `meson-purifier lock` writes next to meson.build.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# meson-purifier overlay (`overlays.default`) adds it to the package set as
# `buildMesonProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildMesonProject }:
#   buildMesonProject {
#     pname = "hello";
#     version = "1.0";
#     src = ./.;
#   }
#
# The builder takes the arguments of stdenv.mkDerivation, and `lockFile`.
# It adds meson, ninja and pkg-config to nativeBuildInputs and points
# Meson's package cache (MESON_PACKAGE_CACHE_DIR) at the locked downloads.
# The nixpkgs Meson setup hook configures with --wrap-mode=nodownload, so
# every subproject comes from that cache. The `meson setup` arguments the
# lock run was given (`meson-purifier lock . -- ARGS`) come before
# `mesonFlags`.
#
# The lockfile records what the project installs, so the result knows its
# outputs without building:
#
#   targets.<name>    the installed files of the build target <name> of the
#                     main project, as links into the one build, with
#                     meta.mainProgram set for an executable
#   lockedOutputs     the record in the lockfile: the type and files of each
#                     target, and every installed file
#
# After `meson install`, the build fails if a recorded file is missing,
# which means the lockfile is older than the build definition.
{
  lib,
  stdenv,
  meson,
  ninja,
  pkg-config,
  callPackage,
  runCommand,
}:
{
  src,
  # The lockfile; the default is the one `meson-purifier lock` writes.
  lockFile ? src + "/meson-purifier.lock.json",
  ...
}@args:
let
  packageCache = callPackage ./package-cache.nix { inherit lockFile; };
  inherit (packageCache) lock;

  # The wrap files of a source given as a path are readable during
  # evaluation, so a lockfile older than them fails here. Other sources are
  # checked by nothing; the build then fails at configure time if a wrap is
  # missing from the cache.
  fresh =
    !(builtins.isPath src)
    ||
      import ./inputs-hash.nix {
        project = src;
        inherit (lock) subprojectsDir;
        installed = map (entry: entry.path) lock.installedWraps;
      } == lock.inputsHash
    || throw "meson-purifier: the wrap files of ${toString src} changed since its lockfile was written. Run `meson-purifier lock`.";

  subprojectsDir = lib.escapeShellArg lock.subprojectsDir;

  # The wraps Meson would install from wrapdb.json at configure time.
  installWraps = lib.concatMapStrings (entry: ''
    if [ ! -e ${subprojectsDir}/${lib.escapeShellArg entry.path} ]; then
      cp ${packageCache}/wrapdb-wraps/${lib.escapeShellArg entry.path} ${subprojectsDir}/
      chmod u+w ${subprojectsDir}/${lib.escapeShellArg entry.path}
    fi
  '') lock.installedWraps;

  checkOutputs = ''
    for file in ${lib.escapeShellArgs lock.outputs.files}; do
      if [ ! -e "$out/$file" ] && [ ! -L "$out/$file" ]; then
        echo "meson-purifier: the lockfile records $file, which meson install did not install. Run \`meson-purifier lock\`." >&2
        exit 1
      fi
    done
  '';

  package = stdenv.mkDerivation (
    builtins.removeAttrs args [ "lockFile" ]
    // {
      nativeBuildInputs = [
        meson
        ninja
        pkg-config
      ]
      ++ args.nativeBuildInputs or [ ];
      mesonFlags = lock.setupArgs ++ args.mesonFlags or [ ];
      preConfigure = installWraps + args.preConfigure or "";
      postInstall = args.postInstall or "" + checkOutputs;
      env = args.env or { } // {
        MESON_PACKAGE_CACHE_DIR = "${packageCache}/cache";
      };
      passthru = args.passthru or { } // {
        inherit packageCache lock targets;
        lockedOutputs = lock.outputs;
      };
    }
  );

  mkTarget =
    name: target:
    runCommand name
      {
        passthru = { inherit package; };
        meta =
          lib.optionalAttrs (target.type == "executable" && target.files != [ ]) {
            mainProgram = baseNameOf (builtins.head target.files);
          }
          // {
            description = "${name}, built by meson-purifier";
          };
      }
      (
        lib.concatMapStrings (file: ''
          mkdir -p "$out"/${lib.escapeShellArg (dirOf file)}
          ln -s ${package}/${lib.escapeShellArg file} "$out"/${lib.escapeShellArg file}
        '') target.files
      );

  targets = lib.mapAttrs mkTarget lock.outputs.targets;
in
assert fresh;
package
