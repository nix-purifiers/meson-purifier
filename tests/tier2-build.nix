# SPDX-License-Identifier: MIT
# Evaluation takes the just-generated host lock; the resulting derivation
# builds in the ordinary Nix sandbox with downloads supplied by its cache.
{
  repository,
  project,
  pname ? "external-fixture",
  version ? "1.0.0",
  result ? "evidence",
}:
let
  isInih = pname == "inih";
  setupArgs =
    if pname == "rizin" then
      "-Dregenerate_cmds=disabled"
    else if isInih then
      "-Dtests=true"
    else
      "--force-fallback-for=zlib,inih";
  flake = builtins.getFlake repository;
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ flake.overlays.default ];
  };
  built = pkgs.meson-purifier.buildMesonProject {
    inherit pname version;
    src = builtins.path {
      path = builtins.toPath project;
      name = "source";
      filter =
        path: type:
        !(builtins.elem (baseNameOf path) [
          "build"
          ".meson-purifier"
          ".git"
        ]);
    };
  };
in
if result == "tests" then
  built.tests
else
  pkgs.runCommand "meson-${pname}-runtime-evidence"
    {
      passthru = { inherit built; };
      nativeBuildInputs = [
        pkgs.meson
        pkgs.ninja
        pkgs.pkg-config
        pkgs.stdenv.cc
        pkgs.python3
      ];
    }
    ''
      mkdir -p "$out"
      ${
        if isInih then
          ''
            mkdir "$out/bin"
            cc ${pkgs.writeText "inih-consumer.c" ''
              #include <ini.h>
              #include <stdio.h>
              #include <string.h>
              static int handler(void *user, const char *section, const char *key, const char *value) {
                if (!strcmp(section, "proof") && !strcmp(key, "answer") && !strcmp(value, "42"))
                  (*(int *)user)++;
                return 1;
              }
              int main(void) {
                int found = 0;
                if (ini_parse_string("[proof]\nanswer=42\n", handler, &found) || found != 1) return 1;
                puts("inih parsed 42");
                return 0;
              }
            ''} -I${built.tests}/include -L${built.tests}/lib \
              -Wl,-rpath,${built.tests}/lib -linih -o "$out/bin/inih-proof"
          ''
        else
          ''ln -s ${built.tests}/bin "$out/bin"''
      }
      cp -R ${built.tests.src} ordinary
      chmod -R u+w ordinary
      cd ordinary
      # inih itself has no wraps. The external fixture proves the nonempty
      # dependency cache and its negative control separately.
      ${pkgs.lib.optionalString (!isInih) ''
        mkdir "$TMPDIR/empty-cache"
        if MESON_PACKAGE_CACHE_DIR="$TMPDIR/empty-cache" meson setup missing \
          --wrap-mode=nodownload ${setupArgs} \
          >"$TMPDIR/missing.log" 2>&1; then
          echo 'ordinary Meson configured without its dependency cache' >&2
          exit 1
        fi
        grep -q 'Automatic wrap-based subproject downloading is disabled' "$TMPDIR/missing.log"
      ''}
      export MESON_PACKAGE_CACHE_DIR=${built.packageCache}/cache
      meson setup build --wrap-mode=nodownload \
        ${setupArgs}
      ${
        if pname == "rizin" then
          ''
            meson compile -C build -j "$NIX_BUILD_CORES" rizin rz-asm
            ./build/binrz/rizin/rizin -v | grep -q 'rizin ${version}'
            test "$(echo 'mov eax, 1' | ./build/binrz/rz-asm/rz-asm -a x86 -b 32 -)" = b801000000
          ''
        else
          ''
            meson compile -C build -j "$NIX_BUILD_CORES"
            meson test -C build
            ${
              if isInih then
                ''
                  python3 - <<'PY'
                  import json
                  tests = json.load(open('build/meson-info/intro-tests.json'))
                  assert len(tests) == 18, tests
                  PY
                ''
              else
                "./build/external-fixture | grep -qx 'external, zlib 1.3.2' "
            }
          ''
      }
      ${
        if pname == "rizin" then
          ''
            "$out/bin/rizin" -v | grep -q 'rizin ${version}'
            test "$(echo 'mov eax, 1' | "$out/bin/rz-asm" -a x86 -b 32 -)" = b801000000
          ''
        else if isInih then
          ''"$out/bin/inih-proof" | grep -qx 'inih parsed 42' ''
        else
          ''
            "$out/bin/external-fixture" | grep -qx 'external, zlib 1.3.2'
          ''
      }
      cp ${
        pkgs.writeText "sdk.json" (
          builtins.toJSON {
            system = pkgs.stdenv.hostPlatform.system;
            meson = {
              version = pkgs.meson.version;
              derivation = pkgs.meson.drvPath;
            };
            python = pkgs.python3.version;
            compiler = pkgs.stdenv.cc.version;
            project = pname;
            inherit version;
            tests = built.tests.drvPath;
          }
        )
      } "$out/sdk.json"
    ''
