# The Subversion export has no Meson build; the wrap's patch_directory adds
# this file. It turns the size of a file of the export into a header, so the
# program shows that the export reached the build.
project('svn-examples', 'c')

fs = import('fs')
conf = configuration_data()
conf.set('SVN_EXAMPLE_SIZE', fs.size('minimal_client.c'))
header = configure_file(output: 'svn_examples.h', configuration: conf)
svn_examples_dep = declare_dependency(
  include_directories: include_directories('.'),
  sources: header,
)
