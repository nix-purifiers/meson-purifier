# tinyexpr has no Meson build of its own; the wrap's patch_directory adds
# this file. The wrap file in subprojects/ beside it is a nested wrap: Meson
# promotes it into the main project when this subproject is configured.
project('tinyexpr', 'c', meson_version: '>=1.3.0')

cc = meson.get_compiler('c')
yaml_dep = dependency('yaml-0.1')
tinyexpr_lib = static_library(
  'tinyexpr',
  'tinyexpr.c',
  dependencies: [cc.find_library('m', required: false), yaml_dep],
)
tinyexpr_dep = declare_dependency(
  include_directories: include_directories('.'),
  link_with: tinyexpr_lib,
  dependencies: [cc.find_library('m', required: false), yaml_dep],
)
