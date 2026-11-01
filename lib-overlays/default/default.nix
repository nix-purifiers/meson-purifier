# SPDX-License-Identifier: MIT
#
# The `meson-purifier` library namespace.
#
#   readLock { src, lockFile ? ... }
#     The lockfile and the wrap files of a project, read into the lock in
#     memory of the purifier contract (nix/lib/read-lock.nix).
#   buildMesonProject { pkgs, src, fetchers ? { }, lockFile ? ..., ... }
#     The sandboxed build of a Meson project from its lockfile
#     (nix/lib/build-meson-project.nix documents its arguments and result).
#     It lays the downloads out with `lib.purifier`, the shared library of
#     the nix-purifiers.
{ ... }:
{

  overlay = final: prev: {
    meson-purifier = prev.meson-purifier or { } // rec {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildMesonProject = import ../../nix/lib/build-meson-project.nix {
        purifierLib = final.purifier;
        inherit readLock;
      };
    };
  };

}
