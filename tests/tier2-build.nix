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
      ];
    }
    ''
      mkdir -p "$out"
      ln -s ${built.tests}/bin "$out/bin"
      cp -R ${built.tests.src} ordinary
      chmod -R u+w ordinary
      cd ordinary
      mkdir "$TMPDIR/empty-cache"
      if MESON_PACKAGE_CACHE_DIR="$TMPDIR/empty-cache" meson setup missing \
        --wrap-mode=nodownload ${
          if pname == "rizin" then "-Dregenerate_cmds=disabled" else "--force-fallback-for=zlib,inih"
        } \
        >"$TMPDIR/missing.log" 2>&1; then
        echo 'ordinary Meson configured without its dependency cache' >&2
        exit 1
      fi
      grep -q 'Automatic wrap-based subproject downloading is disabled' "$TMPDIR/missing.log"
      export MESON_PACKAGE_CACHE_DIR=${built.packageCache}/cache
      meson setup build --wrap-mode=nodownload \
        ${if pname == "rizin" then "-Dregenerate_cmds=disabled" else "--force-fallback-for=zlib,inih"}
      ${
        if pname == "rizin" then
          ''
            meson compile -C build rizin rz-asm
            ./build/binrz/rizin/rizin -v | grep -q 'rizin 0.8.2'
            test "$(echo 'mov eax, 1' | ./build/binrz/rz-asm/rz-asm -a x86 -b 32 -)" = b801000000
          ''
        else
          ''
            meson compile -C build
            meson test -C build
            ./build/external-fixture | grep -qx 'external, zlib 1.3.2'
          ''
      }
      ${
        if pname == "rizin" then
          ''
            "$out/bin/rizin" -v | grep -q 'rizin 0.8.2'
            test "$(echo 'mov eax, 1' | "$out/bin/rz-asm" -a x86 -b 32 -)" = b801000000
          ''
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
