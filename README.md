# meson-purifier

meson-purifier makes Nix the download backend of a Meson build. It records
the files Meson wants to download for its subprojects in a lockfile, so that
Nix can build the project in its sandbox. You do not commit any generated
Nix files to your repository.

- **A lockfile.** `meson-purifier lock` writes `meson-purifier.lock.json`
  next to `meson.build`. It lists every source the project's wrap files
  name: the source and patch archives of each `wrap-file`, and a checkout of
  each `wrap-git`, `wrap-hg` and `wrap-svn`, each with its hash. It also
  lists the wraps Meson installs from `subprojects/wrapdb.json`, and what
  the project installs.
- **Sandboxed builds.** `buildMesonProject`, which the flake's overlay adds
  to a package set, takes the arguments of `stdenv.mkDerivation` and builds
  from the lockfile with no network access. `targets.<name>` is each
  installed target of the project, known from the lockfile without
  building.
- **Interactive Meson on the locked downloads.** The flake's `meson` runs
  the real Meson. In a project with a current lockfile, it first builds the
  locked downloads through Nix and points Meson's package cache at them, so
  `meson setup`, `meson compile` and `meson test` read the same files the
  Nix build reads, offline.

meson-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).
Its design follows sbt-nix-backend, the first of them: the tool keeps
planning the build, a lock run records what the tool downloads, Nix builds
from the lockfile, and the interactive tool reads the same locked downloads.
The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## How it works

Meson resolves a subproject from its package cache before it downloads
anything. The package cache is `subprojects/packagecache`, or the directory
`MESON_PACKAGE_CACHE_DIR` names. For a `wrap-file`, Meson takes the
archives named by `source_filename` and `patch_filename` from the cache and
checks them against the wrap's hashes. For any wrap, a directory in the
cache named like the wrap's `directory` is copied into the subproject
directory in place of a download or a checkout. In both cases Meson then
applies the wrap's `patch_directory` and `diff_files` itself.

meson-purifier builds such a package cache in the Nix store from the
lockfile, and runs Meson with `MESON_PACKAGE_CACHE_DIR` pointing at it and
with `--wrap-mode=nodownload`. Meson does the rest the way it always does,
so `[provide]` sections, `dependency()` fallbacks, nested wraps and patches
behave as they do with the network.

## How the lock is made

`meson-purifier lock` reads the wrap files with Meson's own wrap code, so
it parses them, follows `wrap-redirect` files and merges wraps exactly as
Meson does. For each wrap it fetches the sources:

- **`wrap-file`.** The source and patch archives that have a URL go into
  the store through Nix, checked against `source_hash` and `patch_hash`.
  `source_fallback_url` and `patch_fallback_url` become the entry's
  mirrors. Archives the project carries in `packagefiles/` need no entry.
- **`wrap-git`.** `nix-prefetch-git` fetches the `revision`, which may be a
  branch or tag; the lockfile records the commit it resolved to and the NAR
  hash nixpkgs' `fetchgit` checks. `clone-recursive` sets whether
  submodules are fetched.
- **`wrap-hg`.** The lock run clones and archives the `revision` the way
  nixpkgs' `fetchhg` does, subrepositories included, as Meson's `hg
  checkout` does, and records the full node id.
- **`wrap-svn`.** The lock run exports the `revision` the way nixpkgs'
  `fetchsvn` does, and records the revision number. Subversion expands
  keywords such as `$Date$` in the local time zone, so the export runs with
  `TZ=UTC`, as the sandbox does.

The lock run then lets Meson extract each subproject, with its patches, in
a scratch copy of the subproject directory. A subproject can carry wrap
files of its own, which Meson promotes to the main project when it
configures that subproject; the lock run locks those too.

Last, the lock run configures a copy of the project with the network, using
the options nixpkgs' Meson setup hook passes and the arguments given after
`--`. That finds two things that depend on the configuration:

- **The wraps Meson installs from `subprojects/wrapdb.json`.** When a
  `dependency()` falls back to a WrapDB project that has no wrap file yet,
  Meson downloads the wrap from WrapDB into the subproject directory. The
  lockfile records each such wrap file; builds and interactive commands
  write it there before Meson configures, as Meson would.
- **The outputs.** `meson introspect` lists the installed targets of the
  main project and every file `meson install` installs. The lockfile
  records them relative to the prefix, so the builder knows its outputs at
  evaluation time.

The lockfile records the setup arguments, and the builder passes them to
Meson ahead of `mesonFlags`. It also records two hashes:

- **`wrapsHash`** covers the wrap files, `wrapdb.json` and `Cargo.lock`,
  which decide what the lock run downloads. When one of them changed since
  the lockfile was written, a download may be missing, so the builder fails
  at evaluation time and the interactive commands that need the downloads
  refuse to run, until `meson-purifier lock` renews the lockfile. Wrap files
  that only redirect to a wrap a subproject carries are left out, because
  Meson writes them itself while it configures.
- **`definitionHash`** covers the project's `meson.build` and option
  files, which decide the outputs. When one of them changed, the downloads
  are still current, so interactive commands go on and the builder only
  warns that the recorded targets may be out of date.

## Use

Lock the project, from its directory, in a shell that has the project's
compilers and build dependencies:

```zsh
nix run github:nix-purifiers/meson-purifier -- lock
```

Arguments for `meson setup` go after `--`, and then name the project
directory first:

```zsh
nix run github:nix-purifiers/meson-purifier -- lock . -- -Dtests=false
```

Commit `meson-purifier.lock.json`. The flake's `overlays.default` adds
`buildMesonProject` to a package set, and a package written for
`callPackage` takes it by name, like any other builder:

```nix
# package.nix
{ buildMesonProject }:
buildMesonProject {
  pname = "hello";
  version = "1.0";
  src = ./.;
}
```

```nix
{
  inputs.meson-purifier.url = "github:nix-purifiers/meson-purifier";
  inputs.nixpkgs.follows = "meson-purifier/nixpkgs";

  outputs = { nixpkgs, meson-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          meson-purifier.overlays.default
          (final: prev: { hello = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.hello = pkgs.hello;
    };
}
```

`buildMesonProject` returns the derivation that `stdenv.mkDerivation`
makes, with `meson`, `ninja` and `pkg-config` added to
`nativeBuildInputs`. Its passthru has:

- `targets.<name>`, the installed files of each build target of the main
  project, as links into the one build, with `meta.mainProgram` set for an
  executable;
- `lockedOutputs`, the outputs the lockfile records;
- `packageCache`, the package cache it builds with.

After `meson install` the build checks that every file the lockfile records
was installed, so a build definition that changed in a way the hash does
not see fails there. `lockFile` names another lockfile than the one next to
`meson.build`.

## Interactive Meson

`nix develop github:nix-purifiers/meson-purifier` gives a shell with the
flake's `meson`, `ninja` and `meson-purifier`. Run Meson as usual. In a
project with a lockfile, every `meson` command first builds the package
cache of the lockfile through Nix, under a GC root in
`.meson-purifier/package-cache` in the project, and runs the real Meson with
`MESON_PACKAGE_CACHE_DIR` pointing at it. `meson setup` also gets
`--wrap-mode=nodownload`. A project without a lockfile runs Meson as it
is. Editors and language servers read the build directory as usual:
`compile_commands.json` points into the subprojects Meson extracted from
the package cache, so clangd works offline.

`meson wrap` and `meson subprojects` (other than `download`) run as they
are, without the lockfile, because they are how a dependency is added or
upgraded. To add one, run `meson wrap install <name>`, or write the wrap
file, then `meson-purifier lock`, and go on with `meson setup`.

`meson-purifier download` extracts every subproject of the main project
into the subproject directory, offline, the way `meson subprojects
download` does with the network. `meson-purifier realize` builds the
package cache and prints its path.

## When something is wrong

Every error below names what went wrong and tells you to run
`meson-purifier lock`.

| Situation | Where it shows |
|---|---|
| A wrap file changed after the lock run | interactive commands refuse to run; the builder fails at evaluation time |
| The lockfile lacks a download, as after a hand edit | Meson stops at that subproject, and meson-purifier explains why, interactively and in the Nix build |
| A hash in the lockfile was edited, or an upstream file changed | Nix reports a hash mismatch, and meson-purifier says what it means |
| The lockfile has merge conflict markers or lacks a field | interactive commands and the builder name the problem |
| The lockfile has another format version | interactive commands and the builder name both versions |

## Decisions

- **Meson extracts and patches, not Nix.** The package cache holds what
  Meson would otherwise download, so `patch_directory`, `diff_files`,
  `lead_directory_missing` and the patch archives of WrapDB go through
  Meson's own code.
- **The lock run locks every wrap it can reach,** not only the ones the
  current configuration uses, so changing an option does not need a
  relock to find a subproject's sources.
- **Outputs come from a configuration with nixpkgs' options.** The lock run
  passes the directory options and `-Dauto_features=enabled` and
  `--buildtype=plain` that nixpkgs' Meson setup hook passes, so the
  recorded paths are the paths the Nix build installs to.

## Limits

- **The lock run configures the project,** so it needs the project's
  compilers and the build dependencies Meson looks for. Run it in the
  project's development shell. A dependency the lock environment has but
  the Nix build lacks can hide a subproject fallback from the lock; pass
  `--force-fallback-for` after `--` to lock subprojects regardless.
- **Wraps installed from `wrapdb.json`** are found only for the
  configuration the lock run uses.
- **Cargo subprojects** that Meson reads from `Cargo.lock` reach the lock
  run as wrap-files and lock the same way. The checks of this repository
  exercise C subprojects only.
- **Downloads outside Meson's wrap code,** such as a `custom_target` or
  `run_command` that fetches files, fail in the sandbox.
- **Subprojects with a custom `subproject_dir`** are found when
  `project()` names it as a quoted literal.
