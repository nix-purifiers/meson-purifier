# SPDX-License-Identifier: MIT
#
# The fixture of conformance-update: its zlib wrap pins WrapDB release
# 1.3.1-1, which `meson-purifier update` moves to the latest release.
project('update-fixture', 'c', version: '1.0.0')

zlib = dependency('zlib')
executable(
  'update-fixture',
  'main.c',
  dependencies: zlib,
  install: true,
)
