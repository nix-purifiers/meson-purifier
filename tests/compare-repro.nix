# SPDX-License-Identifier: MIT
# This derivation checks the whole-output identities produced and executed
# by two native Darwin jobs. It does not execute Darwin binaries on Linux.
{
  repository,
  first,
  second,
}:
let
  flake = builtins.getFlake repository;
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  firstReceipts = builtins.path {
    path = builtins.toPath first;
    name = "first-native-receipts";
  };
  secondReceipts = builtins.path {
    path = builtins.toPath second;
    name = "second-native-receipts";
  };
in
pkgs.runCommand "meson-native-canonical-reproducibility" { nativeBuildInputs = [ pkgs.python3 ]; }
  ''
    mkdir "$out"
    python3 ${./compare-repro.py} ${firstReceipts} ${secondReceipts} "$out/result.json"
  ''
