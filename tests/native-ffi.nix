# SPDX-License-Identifier: MIT
{ pkgs, buildMesonProject }:
let
  src = ./fixtures/native-ffi;
  lockFile =
    if pkgs.stdenv.hostPlatform.isDarwin then
      ./fixtures/native-ffi/darwin.lock.json
    else
      ./fixtures/native-ffi/linux.lock.json;
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
