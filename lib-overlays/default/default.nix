# SPDX-License-Identifier: MIT
#
# The `meson-purifier` library namespace.
#
#   readLock { src, lockFile ? ... }
#     The lockfile and the wrap files of a project, read into the lock in
#     memory of the purifier contract (nix/lib/read-lock.nix).
#
# The builder needs a package set, so it is the package `buildMesonProject`
# that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    meson-purifier = prev.meson-purifier or { } // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
