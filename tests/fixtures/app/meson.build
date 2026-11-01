# A program that takes one dependency from each kind of wrap source:
#
#   zlib           a WrapDB wrap-file, with a source and a patch archive
#   inih           a wrap-git at a tag
#   tinyexpr       a wrap-file with patch_directory and diff_files, whose
#                  patch directory carries a nested wrap (libyaml, from WrapDB)
#   libcjson       no wrap file: Meson installs one from subprojects/wrapdb.json
#   hghooks        a wrap-hg
#   svn-examples   a wrap-svn
#
# Each comes in through dependency() and the [provide] section of its wrap.
project('purifier-fixture', 'c', version: '1.0.0', meson_version: '>=1.3.0')

deps = [
  dependency('zlib'),
  dependency('inih'),
  dependency('tinyexpr'),
  dependency('libcjson'),
  dependency('hghooks'),
  dependency('svn-examples'),
]

# Two installed targets, an executable and a library with its header, which
# the lockfile records as the outputs of the project.
greeting = static_library('purifier-greeting', 'greeting.c', install: true)
install_headers('greeting.h')

exe = executable(
  'purifier-fixture',
  'main.c',
  dependencies: deps,
  link_with: greeting,
  install: true,
)
test('purifier-fixture', exe)
