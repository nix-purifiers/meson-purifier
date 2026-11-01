# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;
  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # The packages are the `default` entry of this flake's package overlay
  # registry (pkg-overlays/): the package set applies it by default, and
  # the flake exports it as `pkgOverlays` and as the plain
  # `overlays.default`. The scope `meson-purifier` also holds the builder,
  # which is a function and not a package, so the module of the purifier
  # library exports the derivations of the scope as `packages`.
  purifier.scope = "meson-purifier";

  # `nix run github:nix-purifiers/meson-purifier -- lock` locks the Meson
  # project in the current directory.
  #
  # `nix develop github:nix-purifiers/meson-purifier` gives a shell whose
  # `meson` runs against the project's locked downloads.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.toolchain;
      devShells.default = pkgs.mkShell {
        packages = [ config.packages.toolchain ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.ruff-format.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              mesonPurifier = self.lib.meson-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.ruff-format.enable = true;
          };
      };
  };

}
