# SPDX-License-Identifier: MIT
#
# buildMesonProject: the sandboxed build of a Meson project, from the
# lockfile `meson-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The flake's
# `overlays.default` adds it to the package set as `buildMesonProject`, so
# a package written for callPackage takes it like any other builder:
#
#   { buildMesonProject }:
#   (buildMesonProject { pname = "hello"; version = "1.0"; src = ./.; }).packages.hello
#
# and `buildMesonProject.override` replaces what it takes from the set.
#
# The builder takes the arguments of stdenv.mkDerivation and these:
#
#   src        the project
#   fetchers   fetchers in place of nixpkgs' own, such as a fetchurl with a
#              mirror or credentials; they go to fetchEntry and tree of the
#              purifier library
#   lockFile   the lockfile; the default is meson-purifier.lock.json in
#              `src`, and a lockfile given here replaces any copy in `src`,
#              so a packaging flake can keep the lockfile of a project it
#              does not change
#
# The build adds meson, ninja and pkg-config to nativeBuildInputs, points
# Meson's package cache (MESON_PACKAGE_CACHE_DIR) at the locked downloads,
# and passes the `meson setup` arguments of the lock run (`meson-purifier
# lock . -- ARGS`) before `mesonFlags`. The nixpkgs Meson setup hook
# configures with --wrap-mode=nodownload, so every subproject comes from
# that cache.
#
# The result has, at evaluation time, from the lockfile:
#
#   packages.<name>   the installed files of each build target of the main
#                     project, as links into one build, with
#                     meta.mainProgram set for an executable
#   packages.all      that build: everything `meson install` installs
#   tests             the build with `meson test` run in the sandbox
#   release           the source release `meson dist` makes, which
#                     `meson-purifier publish` uploads
#   fetches           the download entries of the purifier library that
#                     the build fetches: the `entries` of the lock in
#                     memory, which readLock (read-lock.nix) reads from the
#                     lockfile and the wrap files
#   lockedOutputs     the outputs the lockfile records
#   packageCache      the package cache the builds use
#
# After `meson install` the build fails if a file the lockfile records is
# missing, which means the lockfile is older than the build definition.
{
  lib,
  stdenv,
  meson,
  ninja,
  pkg-config,
  runCommand,
  git,
  # What the purifier library fetches and lays out the package cache with.
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  unzip,
  zstd,
  python3,
  writeText,
  # The library of the nix-purifiers (`lib.purifier`) and readLock
  # (read-lock.nix), which the overlay passes from the library of this
  # flake.
  purifierLib,
  readLock,
}:
{
  src,
  fetchers ? { },
  lockFile ? src + "/meson-purifier.lock.json",
  ...
}@args:
let

  # The lock in memory of the purifier contract. checkLock fails the
  # evaluation with its problems: a stale, tampered, malformed or
  # incomplete lockfile, or wrap files that changed since the lock run,
  # which means a download may be missing. A source that a derivation
  # builds cannot be compared at evaluation; there a subproject missing
  # from the package cache fails the build at configure time, with a hint.
  lock = purifierLib.checkLock (readLock {
    inherit src lockFile;
  });
  inherit (lock.meson) subprojectsDir installedWraps;

  packageCache = import ./package-cache.nix {
    inherit purifierLib;
    entries = purifierLib.entriesFor stdenv.hostPlatform.system lock;
    packages = {
      inherit
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
    }
    // fetchers;
  };

  # A changed build definition leaves the downloads alone and only the
  # recorded outputs may be out of date, which is a warning.
  checkDefinition =
    if lock.meson.definitionFresh then
      lib.id
    else
      lib.warn "meson-purifier: the meson.build files of ${toString src} changed since its lockfile was written, so the targets it records may be out of date. Run `meson-purifier lock`.";

  # Meson's message when a subproject is missing from the package cache.
  notDownloadable = "Automatic wrap-based subproject downloading is disabled";
  missingSubprojectHint = ''
    for log_file in $(find "$NIX_BUILD_TOP" -path '*/meson-logs/meson-log.txt' 2>/dev/null); do
      if grep -q ${lib.escapeShellArg notDownloadable} "$log_file"; then
        echo "meson-purifier: Meson needs a subproject that the lockfile does not hold. Run \`meson-purifier lock\`, with the mesonFlags that choose the subprojects after \`--\`." >&2
        break
      fi
    done
  '';

  subprojects = lib.escapeShellArg subprojectsDir;

  # The wraps Meson would install from wrapdb.json at configure time.
  installWraps = lib.concatMapStrings (entry: ''
    if [ ! -e ${subprojects}/${lib.escapeShellArg entry.path} ]; then
      cp ${packageCache}/wrapdb-wraps/${lib.escapeShellArg entry.path} ${subprojects}/
      chmod u+w ${subprojects}/${lib.escapeShellArg entry.path}
    fi
  '') installedWraps;

  checkOutputs = ''
    for file in ${lib.escapeShellArgs lock.meson.files}; do
      if [ ! -e "$out/$file" ] && [ ! -L "$out/$file" ]; then
        echo "meson-purifier: the lockfile records $file, which meson install did not install. Run \`meson-purifier lock\`." >&2
        exit 1
      fi
    done
  '';

  derivationArgs = builtins.removeAttrs args [
    "fetchers"
    "lockFile"
  ];

  common = derivationArgs // {
    nativeBuildInputs = [
      meson
      ninja
      pkg-config
    ]
    ++ args.nativeBuildInputs or [ ];
    mesonFlags = lock.meson.setupArgs ++ args.mesonFlags or [ ];
    preConfigure = installWraps + args.preConfigure or "";
    failureHook = missingSubprojectHint + args.failureHook or "";
    env = args.env or { } // {
      MESON_PACKAGE_CACHE_DIR = "${packageCache}/cache";
    };
  };

  all = stdenv.mkDerivation (
    common
    // {
      postInstall = args.postInstall or "" + checkOutputs;
    }
  );

  tests = all.overrideAttrs (old: {
    pname = "${old.pname}-tests";
    doCheck = true;
  });

  # `meson dist` packs the project from its git repository, so the source
  # becomes a repository of one commit with a fixed date first.
  release = stdenv.mkDerivation (
    common
    // {
      pname = "${all.pname}-release";
      nativeBuildInputs = common.nativeBuildInputs ++ [ git ];
      dontConfigure = true;
      doCheck = false;
      buildPhase = ''
        runHook preBuild
        runHook preConfigure
        export GIT_AUTHOR_DATE=1970-01-01T00:00:01+00:00 GIT_COMMITTER_DATE=1970-01-01T00:00:01+00:00
        export HOME="$TMPDIR"
        git init -q
        git add -A
        git -c user.name=meson-purifier -c user.email=meson-purifier@localhost commit -q -m release
        flagsArray=()
        concatTo flagsArray mesonFlags mesonFlagsArray
        meson setup release-build --wrap-mode=nodownload "''${flagsArray[@]}"
        meson dist -C release-build --no-tests --formats xztar
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp release-build/meson-dist/* "$out"/
        runHook postInstall
      '';
    }
  );

  mkTarget =
    name: target:
    runCommand name
      {
        passthru.package = all;
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
          ln -s ${all}/${lib.escapeShellArg file} "$out"/${lib.escapeShellArg file}
        '') target.files
      );

  targets = lib.mapAttrs mkTarget lock.outputs;
in
assert
  !(targets ? all)
  || throw "meson-purifier: the project has an installed target named `all`, which is the name of packages.all";
checkDefinition {
  packages = targets // {
    inherit all;
  };
  inherit
    tests
    release
    packageCache
    ;
  fetches = lock.entries;
  lockedOutputs = {
    targets = lock.outputs;
    inherit (lock.meson) files;
  };
}
