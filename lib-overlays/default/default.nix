# SPDX-License-Identifier: MIT
#
# The `meson-purifier` library namespace.
#
#   packageCache { pkgs, lockFile }
#     The package cache of a lockfile (nix/lib/package-cache.nix), laid out
#     with `lib.purifier`, the shared library of the nix-purifiers. The
#     interactive commands of the meson-purifier command build it through
#     this flake; `lockFile` may be an absolute path as a string.
#
# The builder needs a package set, so it is the package `buildMesonProject`
# that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    meson-purifier = prev.meson-purifier or { } // {
      packageCache =
        { pkgs, lockFile }:
        pkgs.callPackage ../../nix/lib/package-cache.nix {
          inherit lockFile;
          purifierLib = final.purifier;
        };
    };
  };

}
