# SPDX-License-Identifier: MIT
#
# The fixture of conformance-external: a project that holds only the files
# Meson reads. Its meson-purifier lockfile lies outside it, at
# tests/lockfiles/external.lock.json. zlib is a WrapDB wrap-file, whose
# archives the build reads from the wrap file; inih is a wrap-git, whose
# checkout the lockfile records.
project('external-fixture', 'c', version: '1.0.0')

executable(
  'external-fixture',
  'main.c',
  dependencies: [dependency('zlib'), dependency('inih')],
  install: true,
)
