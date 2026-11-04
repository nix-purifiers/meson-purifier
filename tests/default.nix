# SPDX-License-Identifier: MIT
#
# The flake's checks: the purifier contract's conformance checks that run in
# the sandbox, the fixture project built offline from its lockfile, a
# pinned real-world project, and the meson-purifier command with its unit
# tests. The conformance checks that need the network or Nix itself
# (conformance-relock, conformance-rebuild, conformance-offline and
# conformance-update) are CI jobs of those names.
#
# The lockfiles with faults lie in tests/lockfiles/, written by
# tests/negative-locks.py: `nix flake check --no-build` evaluates without
# writing to the store, so the checks read every lockfile from a file.
{
  pkgs,
  overlay,
  mesonPurifier,
}:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand;
  inherit (mesonPurifier) readLock;
  inherit (pkgs'.meson-purifier) buildMesonProject;
  inherit (pkgs'.meson-purifier) cli;

  # The fixture project, which was locked with --force-fallback-for, so
  # that it takes each dependency from a subproject; the builder applies
  # the arguments the lockfile records.
  fixture =
    args:
    buildMesonProject (
      {
        pname = "purifier-fixture";
        version = "1.0.0";
        src = ./fixtures/app;
      }
      // args
    );
  app = fixture { };
  fixtureLock = builtins.fromJSON (builtins.readFile ./fixtures/app/meson-purifier.lock.json);

  # The problems readLock finds in the fixture with one of the lockfiles of
  # tests/lockfiles.
  problemsWith =
    name:
    (readLock {
      src = ./fixtures/app;
      lockFile = ./lockfiles + "/${name}";
    }).problems;
  # Whether one of the problems with that lockfile says `text`.
  fails =
    name: text:
    builtins.any (lib.hasInfix text) (problemsWith name)
    && builtins.all (lib.hasInfix "meson-purifier lock") (problemsWith name);
  evaluates = value: (builtins.tryEval (builtins.deepSeq value value)).success;
  # The builder fails evaluation with that lockfile.
  builderFails =
    name: !evaluates (fixture { lockFile = ./lockfiles + "/${name}"; }).packages.all.drvPath;

  # `meson setup` through meson-purifier in a copy of the fixture with the
  # lockfile `name`, after `prepare`, must fail with a message that names
  # `pattern` and `meson-purifier lock`. The lockfile checks come before
  # any build of the package cache, so this needs no Nix in the sandbox.
  cliFails =
    check:
    {
      name ? null,
      prepare ? "",
      pattern,
    }:
    runCommand check { } ''
      cp -r ${./fixtures/app} app
      chmod -R u+w app
      cd app
      ${lib.optionalString (name != null) "cp ${./lockfiles + "/${name}"} meson-purifier.lock.json"}
      ${prepare}
      if ${lib.getExe cli} meson setup build 2>error; then
        echo "meson-purifier accepted the lockfile" >&2
        exit 1
      fi
      cat error
      grep -q ${lib.escapeShellArg pattern} error
      grep -q 'meson-purifier lock' error
      touch $out
    '';

  runsFixture =
    program:
    runCommand "run-${program.name}" { } ''
      ${lib.getExe program} > output
      cat output
      grep -qx 'purified by Nix, hello, 14, libyaml 0.2.5, hg [0-9]* bytes, svn [0-9]* bytes' output
      touch $out
    '';

  external = buildMesonProject {
    pname = "external-fixture";
    version = "1.0.0";
    src = ./fixtures/external;
    lockFile = ./lockfiles/external.lock.json;
  };

  rizin = buildMesonProject {
    pname = "rizin";
    version = "0.8.2";
    # builtins.fetchTarball fetches at evaluation, so the build reads the
    # wrap files of rizin from it.
    src = builtins.fetchTarball {
      url = "https://github.com/rizinorg/rizin/archive/5a611eee2999d312317ff90d600e37dde0f58992.tar.gz";
      sha256 = "sha256-+3p3urhcRBASLMAExXbSq0BnmlPqF8OSSnBPmGVTPZU=";
    };
    # rizin does not carry a meson-purifier lockfile, so this repository
    # keeps it.
    lockFile = ./real-world/rizin.lock.json;
  };

  # The lockfiles of these checks record the files a Linux install gives,
  # such as lib/libz.so, lib/libz.so.1 and lib/libz.so.1.3.2, where macOS
  # installs lib/libz.dylib and lib/libz.1.dylib, so the builder's check of
  # the installed files fails there. A lockfile holds the outputs of one
  # platform, so these checks run on Linux only.
  linuxLocked = [
    "conformance-external"
    "fixture-app"
    "fixture-tests"
    "fixture-packages"
    "real-world-rizin"
  ];
in
lib.filterAttrs (name: _: pkgs.stdenv.hostPlatform.isLinux || !builtins.elem name linuxLocked) {
  native-ffi = import ./native-ffi.nix {
    pkgs = pkgs';
    inherit buildMesonProject;
  };
  # A lockfile older than the wrap files fails at evaluation, and in the
  # command with a message that names `meson-purifier lock`.
  conformance-stale =
    assert fails "stale.json" "wrap files";
    assert builderFails "stale.json";
    cliFails "conformance-stale" {
      prepare = "echo '# changed' >> subprojects/zlib.wrap";
      pattern = "wrap files changed";
    };

  # A lockfile with a hash changed by hand fails, at evaluation and in the
  # command, because its contentHash no longer matches.
  conformance-tampered =
    assert fails "tampered.json" "edited by hand";
    assert builderFails "tampered.json";
    cliFails "conformance-tampered" {
      name = "tampered.json";
      pattern = "edited by hand";
    };

  # A lockfile without a download it needs fails the build at configure
  # time, with a hint to relock.
  conformance-missing =
    let
      failure =
        pkgs'.testers.testBuildFailure
          (fixture { lockFile = ./lockfiles/missing.json; }).packages.all;
    in
    runCommand "conformance-missing" { } ''
      grep -q 'Automatic wrap-based subproject downloading is disabled' ${failure}/testBuildFailure.log
      grep -q 'Run `meson-purifier lock`' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A lockfile that is not valid fails at evaluation and in the command:
  # merge conflict markers, a missing field, an entry with no source, a
  # path outside the package cache, a wrap file outside the subproject
  # directory, another format version, and wrap files that a source built
  # by a derivation cannot give at evaluation.
  conformance-malformed =
    assert fails "conflicted.json" "merge conflict markers";
    assert fails "no-outputs.json" "lacks outputs";
    assert fails "no-source.json" "without exactly one url";
    assert fails "escaping-path.json" "not a single file name";
    assert fails "bad-wrap-file.json" "not the name of a wrap file";
    assert fails "old-version.json" "lock format version 2";
    assert builderFails "conflicted.json";
    assert builtins.any (lib.hasInfix "--record-all")
      (readLock {
        src = runCommand "built-source" { } "mkdir $out";
        lockFile = ./fixtures/app/meson-purifier.lock.json;
      }).problems;
    # A lockfile older than the build definition evaluates, with a warning.
    assert problemsWith "stale-definition.json" == [ ];
    assert
      !(readLock {
        src = ./fixtures/app;
        lockFile = ./lockfiles/stale-definition.json;
      }).meson.definitionFresh;
    cliFails "conformance-malformed" {
      name = "conflicted.json";
      pattern = "not valid JSON";
    };

  # A project whose source holds only Meson files builds from a
  # meson-purifier lockfile kept outside it.
  conformance-external = runCommand "conformance-external" { } ''
    ${lib.getExe external.packages.external-fixture} | grep -qx 'external, zlib 1.3.2'
    touch $out
  '';

  # The fixture, built and installed in the sandbox from the locked
  # downloads, and its installed program run here.
  fixture-app = runsFixture app.packages.purifier-fixture;

  # The fixture with `meson test`.
  fixture-tests = app.tests;

  # The lock in memory has the shape of the purifier contract, and the
  # packages are known at evaluation time from it: one per installed
  # target of the main project, and `all`.
  fixture-packages =
    let
      lock = readLock { src = ./fixtures/app; };
    in
    assert lock.purifier == "meson-purifier";
    assert lock.problems == [ ];
    assert
      builtins.attrNames lock.outputs == [
        "purifier-fixture"
        "purifier-greeting"
      ];
    assert
      builtins.attrNames app.packages == [
        "all"
        "purifier-fixture"
        "purifier-greeting"
      ];
    assert app.packages.purifier-fixture.meta.mainProgram == "purifier-fixture";
    assert builtins.elem "include/greeting.h" app.lockedOutputs.files;
    runCommand "fixture-packages" { } ''
      test -x ${app.packages.purifier-fixture}/bin/purifier-fixture
      test -f ${app.packages.purifier-greeting}/lib/libpurifier-greeting.a
      test -f ${app.packages.all}/include/greeting.h
      touch $out
    '';

  # The overlay adds one attribute, the scope `meson-purifier`. A package
  # written for callPackage takes the builder through the scope,
  # buildMesonProject.override replaces what the builder takes, and
  # overrideScope replaces what the scope shares.
  builder-package =
    let
      fixtureArgs = {
        pname = "purifier-fixture";
        version = "1.0.0";
        src = ./fixtures/app;
      };
      consumer = pkgs'.callPackage (
        { meson-purifier }: (meson-purifier.buildMesonProject fixtureArgs).packages.purifier-fixture
      ) { };
      overridden = buildMesonProject.override { ninja = pkgs'.samurai; };
      scoped = pkgs'.meson-purifier.overrideScope (self: super: { ninja = pkgs'.samurai; });
      added = builtins.attrNames (builtins.removeAttrs (overlay pkgs pkgs) [ "meson-purifier" ]);
    in
    assert added == [ ];
    assert consumer.drvPath == app.packages.purifier-fixture.drvPath;
    assert (overridden fixtureArgs).packages.all.drvPath != app.packages.all.drvPath;
    assert
      (scoped.buildMesonProject fixtureArgs).packages.all.drvPath == (overridden fixtureArgs)
      .packages.all.drvPath;
    runCommand "builder-package" { } "touch $out";

  # The source release `meson dist` makes, which `publish` uploads.
  fixture-release = runCommand "fixture-release" { } ''
    test -f ${app.release}/purifier-fixture-1.0.0.tar.xz
    test -f ${app.release}/purifier-fixture-1.0.0.tar.xz.sha256sum
    touch $out
  '';

  # `fetches` lists the entries of the lock, which the package cache holds:
  # a file per wrap-file archive, a directory per checkout, and the wraps
  # Meson installs from wrapdb.json. The archives of zlib.wrap and
  # tinyexpr.wrap come from those wrap files.
  fixture-fetches =
    assert
      fixtureLock.wrapFiles == [
        "tinyexpr.wrap"
        "zlib.wrap"
      ];
    assert !builtins.any (entry: lib.hasPrefix "zlib" entry.path) fixtureLock.artifacts;
    assert builtins.length app.fetches == builtins.length fixtureLock.artifacts + 3 + 1;
    runCommand "fixture-fetches" { } ''
      cache=${app.packageCache}
      test -f "$cache/cache/zlib-1.3.2.tar.xz"
      test -f "$cache/cache/zlib_1.3.2-1_patch.zip"
      test -f "$cache/cache/tinyexpr-ba2e32bbcc2d1e644a7e132d24c2f542821cabe0.tar.gz"
      test -f "$cache/cache/inih/ini.c"
      test -f "$cache/cache/hghooks/README"
      test -f "$cache/cache/svn-examples/minimal_client.c"
      test -f "$cache/wrapdb-wraps/cjson.wrap"
      touch $out
    '';

  # The INI reader of wrap files reads what configparser reads: `:` as
  # well as `=`, keys in any case, comments, CRLF line ends, and indented
  # continuation lines.
  wrap-file-reader =
    let
      read = import ../nix/lib/wrap-file.nix { inherit lib; } "t.wrap";
      digest = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23";
      entries = read (
        "; a comment\r\n[wrap-file]\r\n  # another\r\nDirectory = z\r\n"
        + "Source_URL: https://a/z.tar.gz\r\nsource_filename=z.tar.gz\r\n"
        + "source_hash = ${lib.toUpper digest}   \r\ndiff_files = a.diff,\r\n  b.diff\r\n"
        + "\r\n[provide]\r\nz = z_dep\r\n"
      );
    in
    assert
      entries == [
        {
          path = "z.tar.gz";
          url = "https://a/z.tar.gz";
          mirrors = [ ];
          hash = builtins.convertHash {
            hash = digest;
            hashAlgo = "sha256";
            toHashFormat = "sri";
          };
        }
      ];
    assert !(builtins.tryEval (read "[wrap-git]\nurl = x\n")).success;
    runCommand "wrap-file-reader" { } "touch $out";

  # rizin 0.8.2, pinned, built from a lockfile kept in this repository: git
  # wraps on branches and tags, file wraps with fallback URLs, wraps for the
  # build machine, and patch directories.
  real-world-rizin = runCommand "real-world-rizin" { } ''
    ${lib.getExe rizin.packages.rizin} -v | grep -q 'rizin 0.8.2'
    test "$(echo 'mov eax, 1' | ${lib.getExe rizin.packages.rz-asm} -a x86 -b 32 -)" = b801000000
    touch $out
  '';

  # The meson-purifier command, with its unit tests run in the build, and
  # the toolchain around it.
  inherit (pkgs'.meson-purifier) cli toolchain;
}
