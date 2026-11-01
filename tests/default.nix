# SPDX-License-Identifier: MIT
#
# The flake's checks: the fixture project built offline from its lockfile,
# the meson-purifier command with its unit tests, and the behaviour of the
# Nix library on its own.
{ pkgs, overlay }:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand;

  # The fixture was locked with --force-fallback-for, so that it takes each
  # of its dependencies from a subproject also on a system that has some of
  # them installed; the builder applies the arguments the lockfile records.
  app = pkgs'.buildMesonProject {
    pname = "purifier-fixture";
    version = "1.0.0";
    src = ./fixtures/app;
    doCheck = true;
  };

  # The fixture lockfile with some fields replaced.
  fixtureLock = builtins.fromJSON (builtins.readFile ./fixtures/app/meson-purifier.lock.json);
  lockWith =
    fields: builtins.toFile "meson-purifier.lock.json" (builtins.toJSON (fixtureLock // fields));
  evaluates = value: (builtins.tryEval (builtins.deepSeq value value)).success;
  appWithLock =
    lockFile:
    (pkgs'.buildMesonProject {
      pname = "purifier-fixture";
      version = "1.0.0";
      src = ./fixtures/app;
      inherit lockFile;
    }).drvPath;
in
{
  # The fixture, built and installed in the sandbox from the locked
  # downloads, with its test run by `meson test`, and its installed program
  # run here.
  fixture-app = runCommand "fixture-app" { } ''
    ${lib.getExe app.targets.purifier-fixture} > output
    cat output
    grep -qx 'purified by Nix, hello, 14, libyaml 0.2.5, hg [0-9]* bytes, svn [0-9]* bytes' output
    touch $out
  '';

  # The outputs of the fixture are known at evaluation time, from the
  # lockfile: one attribute per installed target of the main project, each
  # holding the files of that target.
  fixture-targets =
    assert
      builtins.attrNames app.targets == [
        "purifier-fixture"
        "purifier-greeting"
      ];
    assert app.targets.purifier-fixture.meta.mainProgram == "purifier-fixture";
    assert builtins.elem "include/greeting.h" app.lockedOutputs.files;
    runCommand "fixture-targets" { } ''
      test -x ${app.targets.purifier-fixture}/bin/purifier-fixture
      test -f ${app.targets.purifier-greeting}/lib/libpurifier-greeting.a
      test -f ${app}/include/greeting.h
      touch $out
    '';

  # The package cache holds a file per wrap-file archive, a directory per
  # checkout, and the wraps Meson installs from wrapdb.json.
  fixture-package-cache = runCommand "fixture-package-cache" { } ''
    cache=${app.packageCache}
    test -f "$cache/cache/zlib-1.3.2.tar.xz"
    test -f "$cache/cache/zlib_1.3.2-1_patch.zip"
    test -f "$cache/cache/inih/ini.c"
    test -f "$cache/cache/hghooks/README"
    test -f "$cache/cache/svn-examples/minimal_client.c"
    test -f "$cache/wrapdb-wraps/cjson.wrap"
    touch $out
  '';

  # The meson-purifier command, with its unit tests run in the build, and
  # the toolchain around it.
  inherit (pkgs'.meson-purifier) cli toolchain;

  # The library rejects a lockfile of another format version, a lockfile
  # older than the wrap files and build definition beside it, and a path
  # that leaves the package cache.
  lock-checks =
    assert evaluates (appWithLock ./fixtures/app/meson-purifier.lock.json);
    assert
      !evaluates (
        appWithLock (lockWith {
          version = 0;
        })
      );
    assert
      !evaluates (
        appWithLock (lockWith {
          inputsHash = "0";
        })
      );
    assert
      !evaluates (
        appWithLock (lockWith {
          artifacts = [
            {
              path = "../escape";
              url = "https://example.org/x";
              mirrors = [ ];
              hash = lib.fakeHash;
            }
          ];
        })
      );
    runCommand "lock-checks" { } "touch $out";
}
