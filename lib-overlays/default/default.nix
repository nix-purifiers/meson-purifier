# SPDX-License-Identifier: MIT
#
# The `meson-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildMesonProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    meson-purifier = prev.meson-purifier or { };
  };

}
