# SPDX-License-Identifier: MIT
# Evaluation takes the just-generated host lock; the resulting derivation
# builds in the ordinary Nix sandbox with downloads supplied by its cache.
{
  repository,
  project,
  pname ? "external-fixture",
  version ? "1.0.0",
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
pkgs.runCommand "meson-${pname}-runtime-evidence"
  {
    passthru = { inherit built; };
  }
  ''
    mkdir -p "$out"
    ln -s ${built.tests}/bin "$out/bin"
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
