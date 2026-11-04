# SPDX-License-Identifier: MIT
{ pkgs, buildMesonProject }:
let
  src = ./fixtures/native-ffi;
  hashes = import ../nix/lib/inputs-hash.nix {
    project = src;
    subprojectsDir = "subprojects";
  };
  body = {
    version = 3;
    subprojectsDir = "subprojects";
    wrapsHash = hashes.wraps;
    definitionHash = hashes.definition;
    setupArgs = [ "--libdir=lib" ];
    installedWraps = [ ];
    wrapFiles = [ ];
    artifacts = [ ];
    outputs = {
      files = [
        "lib/libproof${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
        "include/proof.h"
        "lib/pkgconfig/proof.pc"
      ];
      targets.proof = {
        type = "shared library";
        files = [ "lib/libproof${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}" ];
      };
    };
  };
  lockFile = pkgs.writeText "meson-purifier.lock.json" (
    builtins.toJSON (
      body
      // {
        contentHash = builtins.hashString "sha256" (builtins.toJSON body);
      }
    )
  );
  built = buildMesonProject {
    inherit src lockFile;
    pname = "ffi";
    version = "1";
    buildInputs = [ pkgs.zlib ];
  };
  ffi = built.packages.proof.projections;
in
assert built.fetches == [ ];
pkgs.runCommand "meson-native-foreign-consumer" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  PYTHONPATH=${ffi.python-ffi} python - <<'PY'
  import json, purifier_native
  assert purifier_native.load("proof").answer() == 42
  value = json.load(open('${ffi.native.catalog}'))
  assert value['includeDirectories'] and value['pkgConfigDirectories']
  PY
  touch $out
''
