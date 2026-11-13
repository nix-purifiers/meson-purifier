# SPDX-License-Identifier: MIT
#
# The meson-purifier command. It runs on the Python of the package set with
# Meson's own modules on its path, because the lock run reads wrap files
# with Meson's wrap code. Its unit tests run in the build.
{
  lib,
  stdenvNoCC,
  python3,
  meson,
  git,
  makeWrapper,
}:
let
  mesonModules = "${meson}/${python3.sitePackages}";
in
stdenvNoCC.mkDerivation {
  pname = "meson-purifier";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./meson_purifier.py
      ./test_meson_purifier.py
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    python3
    git
  ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    if [ ! -d ${mesonModules}/mesonbuild ]; then
      echo "meson's modules are not at ${mesonModules}" >&2
      exit 1
    fi
    PYTHONPATH=${mesonModules} python3 -m unittest -v test_meson_purifier
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 meson_purifier.py "$out/libexec/meson-purifier/meson_purifier.py"
    makeWrapper ${python3.interpreter} "$out/bin/meson-purifier" \
      --add-flags "$out/libexec/meson-purifier/meson_purifier.py" \
      --prefix PYTHONPATH : ${mesonModules}
    runHook postInstall
  '';

  meta = {
    description = "Nix as the download backend of Meson subprojects";
    license = lib.licenses.mit;
    mainProgram = "meson-purifier";
  };
}
