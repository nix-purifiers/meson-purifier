# The Mercurial checkout has no Meson build; the wrap's patch_directory adds
# this file. It turns the size of a file of the checkout into a header, so
# the program shows that the checkout reached the build.
project('hghooks', 'c')

fs = import('fs')
conf = configuration_data()
conf.set('HGHOOKS_README_SIZE', fs.size('README'))
header = configure_file(output: 'hghooks.h', configuration: conf)
hghooks_dep = declare_dependency(
  include_directories: include_directories('.'),
  sources: header,
)
