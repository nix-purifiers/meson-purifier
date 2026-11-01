# SPDX-License-Identifier: MIT
#
# The two hashes a lockfile records about the project it was made from.
# `meson-purifier lock` computes them with the same rules (wraps_hash and
# definition_hash in pkgs/cli/meson_purifier.py).
#
#   wraps        the files that decide what a lock run downloads: the wrap
#                files and wrapdb.json in the subproject directory, and a
#                Cargo.lock at the project root, each as its name, a
#                newline, its contents and a newline, in byte order of the
#                names. Two kinds of wrap file are left out. The ones named
#                in `installed` are the wraps the lockfile itself installs
#                from wrapdb.json. A file that starts with [wrap-redirect]
#                only selects a wrap that a subproject carries; Meson writes
#                one when it uses such a wrap, and the lock run locks every
#                wrap that a subproject carries.
#   definition   the build definition, which decides the outputs the lock
#                run records: meson.build and option files, each as its
#                path relative to the project root, a newline, its contents
#                and a newline, in byte order of the paths. The subproject
#                directory, directories whose name starts with a dot, and
#                Meson build directories (the ones holding meson-private)
#                are left out.
#
# Needs no nixpkgs. `project` is the project root as a path.
{
  project,
  subprojectsDir,
  installed ? [ ],
}:
let
  directory = project + "/${subprojectsDir}";
  entries = if builtins.pathExists directory then builtins.readDir directory else { };
  redirect = "[wrap-redirect]";
  # builtins.attrNames returns the names in byte order.
  names = builtins.filter (
    name:
    entries.${name} != "directory"
    && (builtins.match ".*\\.wrap" name != null || name == "wrapdb.json")
    && !(builtins.elem name installed)
    &&
      builtins.substring 0 (builtins.stringLength redirect) (builtins.readFile (directory + "/${name}"))
      != redirect
  ) (builtins.attrNames entries);
  part = name: path: name + "\n" + builtins.readFile path + "\n";
  cargoLock = project + "/Cargo.lock";

  definitionNames = [
    "meson.build"
    "meson.options"
    "meson_options.txt"
  ];
  definitionFiles =
    dir: rel:
    let
      dirEntries = builtins.readDir dir;
    in
    builtins.concatMap (
      name:
      let
        relName = if rel == "" then name else "${rel}/${name}";
        type = dirEntries.${name};
      in
      if type == "directory" then
        if
          builtins.substring 0 1 name == "."
          || relName == subprojectsDir
          || builtins.readDir (dir + "/${name}") ? "meson-private"
        then
          [ ]
        else
          definitionFiles (dir + "/${name}") relName
      else if builtins.elem name definitionNames then
        [ relName ]
      else
        [ ]
    ) (builtins.attrNames dirEntries);
  definition = builtins.sort builtins.lessThan (definitionFiles project "");
in
{
  wraps = builtins.hashString "sha256" (
    builtins.concatStringsSep "" (map (name: part name (directory + "/${name}")) names)
    + (if builtins.pathExists cargoLock then part "Cargo.lock" cargoLock else "")
  );
  definition = builtins.hashString "sha256" (
    builtins.concatStringsSep "" (map (rel: part rel (project + "/${rel}")) definition)
  );
}
