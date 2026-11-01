# meson-purifier

meson-purifier makes Nix the download backend of a Meson build. Meson keeps
planning the build from its wrap files. `meson-purifier lock` records what
the wrap files cannot say, and Nix builds the project in its sandbox from
the wrap files and that lockfile. The same downloads serve `meson setup`,
`meson compile` and `meson test` at the desk, offline.

meson-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io),
which share one builder interface and the commands `lock`, `update`,
`prefetch` and `publish`.

## Quickstart

Lock the project, from its directory, in a shell that has its compilers and
build dependencies. Arguments for `meson setup` go after `--`:

```zsh
nix run github:nix-purifiers/meson-purifier -- lock . -- -Dtests=false
```

Meson has no lockfile of its own. The wrap files in `subprojects/` name
each subproject and belong to the build definition, so meson-purifier
reads them from the source, and the builder and the commands take
no separate build tool lockfile. `meson-purifier.lock.json` lies next to
`meson.build`; commit it with the wrap files, which is the setup we
recommend. The flake's `overlays.default` adds one attribute to a package
set, the scope `meson-purifier`, which holds the builder
`buildMesonProject`, the command and the toolchain. A package written for
`callPackage` takes the scope by name:

```nix
# package.nix
{ meson-purifier }:
(meson-purifier.buildMesonProject {
  pname = "hello";
  version = "1.0";
  src = ./.;
}).packages.hello
```

```nix
# flake.nix
{
  inputs.meson-purifier.url = "github:nix-purifiers/meson-purifier";
  inputs.nixpkgs.follows = "meson-purifier/nixpkgs";

  outputs = { nixpkgs, meson-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ meson-purifier.overlays.default ];
      };
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
    };
}
```

`buildMesonProject` takes the arguments of `stdenv.mkDerivation` and these:

- `src`, the project;
- `lockFile`, the lockfile, by default `meson-purifier.lock.json` in `src`.
  A lockfile given here takes the place of any lockfile in `src`, so a
  packaging flake can keep the lockfile of a project it does not change;
- `fetchers`, fetchers in place of nixpkgs' own, such as a `fetchurl` with a
  company mirror or credentials. They go to `fetchEntry` and `tree` of the
  [purifier](https://github.com/nix-purifiers/purifier) library.

It takes `stdenv`, `meson`, `ninja`, `pkg-config` and the fetchers from the
package set. `meson-purifier.buildMesonProject.override` replaces them for
the builder, and `meson-purifier.overrideScope` replaces them for
everything in the scope.

The result has, all known at evaluation time from the lockfile:

- `packages.<target>`, the installed files of each build target of the main
  project, as links into one build, with `meta.mainProgram` set for an
  executable, and `packages.all`, that build;
- `tests`, the build with `meson test` run in the sandbox;
- `release`, the source tarball `meson dist` makes, which `meson-purifier
  publish` uploads;
- `fetches`, the download entries of the purifier library that the build
  fetches, for SBOM, license and vulnerability tools;
- `lockedOutputs` and `packageCache`.

`lib.meson-purifier.readLock { src, lockFile }` reads the lockfile and the
wrap files into the lock in memory that every purifier gives: `purifier`,
`entries`, `outputs` and `problems`. The builder passes it to `checkLock` of
the purifier library, which fails evaluation with the problems.

## Development loop

`nix develop github:nix-purifiers/meson-purifier` gives a shell with the
flake's `meson`, `ninja` and `meson-purifier`. Run Meson as usual:

```zsh
meson setup build
meson compile -C build
meson test -C build
```

Meson has no plugin mechanism, so this `meson` is a wrapper around the real
Meson. In a project with a lockfile, every `meson` command first builds the
package cache of the lockfile through Nix and runs the real Meson with
`MESON_PACKAGE_CACHE_DIR` pointing at it; `meson setup` also gets
`--wrap-mode=nodownload`. Meson resolves a subproject from its package
cache before it downloads anything, so it reads the files the Nix build
reads and applies `patch_directory`, `diff_files` and patch archives with
its own code.

`meson wrap` and `meson subprojects` (other than `download`) run without
the lockfile, because they are how a dependency is added or upgraded. To add
one, run `meson wrap install <name>`, or write the wrap file, then
`meson-purifier lock`.

`meson-purifier update` runs `meson wrap update`, which moves the WrapDB
wraps to their latest releases, and locks again with the `meson setup`
arguments the lockfile records. `meson-purifier update zlib` updates only
the named wraps. `meson-purifier lock` keeps the wraps as they are.

Wrap files record no commit for a `wrap-git` that follows a branch, so
`meson-purifier lock` resolves the branch to its current commit at each
run, and a relock picks up new commits on it. A `revision` that names a tag
or a commit keeps the lockfile the same from one lock to the next.

`meson-purifier download` extracts every subproject of the main project
into the subproject directory, offline, the way `meson subprojects download`
does with the network. `meson-purifier publish <tag>` builds the `release`
of the flake in the current directory and uploads its files to the GitHub
release `<tag>` with `gh`.

Every command takes `--lockfile <path>` for a lockfile kept outside the
project, and the toolchain `meson` reads `MESON_PURIFIER_LOCKFILE`. A dev
shell can set that variable to the path it passes as `lockFile`.

## Working offline

`meson-purifier prefetch` builds the package cache of the lockfile in the
Nix store, keeps it under a GC root at `.meson-purifier/package-cache`
beside the lockfile, and prints its path. After it, `meson setup`, `meson compile`,
`meson test` and the editor work with the network cut off; Meson, ninja and
the compilers come from the Nix store already.

## Editor

Editors and language servers read the build directory as usual.
`compile_commands.json` points into the subprojects Meson extracted from the
package cache, so clangd finds every header offline.

## Troubleshooting

Every error names the problem and the command that fixes it.

| Situation | What happens | Fix |
|---|---|---|
| A wrap file changed after the lock run | interactive commands refuse to run; the builder fails at evaluation time | `meson-purifier lock` |
| A `meson.build` file changed after the lock run | the downloads are current, so commands go on; the builder warns that the recorded targets may be out of date | `meson-purifier lock` |
| The lockfile was edited by hand | its `contentHash` does not match; commands and the builder refuse it | `meson-purifier lock` |
| The lockfile lacks a download | Meson stops at that subproject, and meson-purifier explains why, interactively and in the Nix build | `meson-purifier lock`, with the setup arguments that choose the subproject after `--` |
| An upstream file changed | Nix reports a hash mismatch, and meson-purifier says what it means | `meson-purifier lock` |
| The lockfile has merge conflict markers, lacks a field, or has another format version | commands and the builder name the problem | `meson-purifier lock` |
| `src` is built by a derivation, so Nix cannot read its wrap files at evaluation | the builder names the problem | `meson-purifier lock --record-all`, or a `src` from a flake input or `builtins.fetchTarball` |

## Supported language repositories

meson-purifier fetches what Meson wrap files name: archives from
[WrapDB](https://mesonbuild.com/Wrapdb-projects.html) and from any URL, and
checkouts from git, Mercurial and Subversion repositories. `meson-purifier
lock` reads the wrap files with Meson's own wrap code, so it parses them,
follows `wrap-redirect` files and merges wraps as Meson does. The lockfile
records what the wrap files cannot say:

| Source | In the lockfile | Why |
|---|---|---|
| `wrap-file` in the subproject directory | its name, in `wrapFiles` | the wrap names its archives with URLs and SHA-256 hashes; Nix reads them from the wrap file at evaluation |
| `wrap-file` inside a download or a patch directory | its archives, with fallback URLs as mirrors | Nix could read that wrap file only by building the download first |
| wraps Meson installs from `subprojects/wrapdb.json` | the wrap and its archives | Meson downloads the wrap itself while it configures |
| `wrap-git` | the commit and NAR hash | a wrap names a branch, tag or revision and no content hash; a branch is resolved with `git ls-remote` |
| `wrap-hg` | the full node id and NAR hash | as for git; subrepositories are included, as `hg checkout` does |
| `wrap-svn` | the revision number and NAR hash | as for git; the export runs with `TZ=UTC`, so expanded keywords match the sandbox |
| the outputs and the `meson setup` arguments | installed targets and files | they come from configuring the project |

Wrap files are INI files, which Meson reads with Python's configparser.
`nix/lib/wrap-file.nix` reads the part of the syntax wrap files use:
sections, `key = value` and `key: value`, lowercased keys, full-line `#` and
`;` comments, and indented continuation lines. Nix reads wrap files from a
`src` that is a path, a flake input, or the result of `builtins.fetchTarball`
or `builtins.fetchGit`. For a `src` that a derivation builds, such as
`fetchFromGitHub`, lock with `--record-all`, which records the archives of
every wrap.

The lock run also configures a copy of the project with the network and
nixpkgs' setup options. That finds the wraps installed from `wrapdb.json`
and the outputs. It locks every wrap it can reach, so a change of options
finds its subprojects in the lockfile.

Cargo subprojects that Meson reads from `Cargo.lock` reach the lock run as
wrap-files and lock the same way. A custom `subproject_dir` is found when
`project()` names it as a quoted literal.

These fail or need a step from you:

- **downloads outside Meson's wrap code,** such as a `custom_target` or
  `run_command` that fetches files, fail in the sandbox;
- **wraps installed from `wrapdb.json`** are found for the configuration the
  lock run uses;
- **a dependency the lock environment has but the Nix build lacks** can hide
  a subproject fallback from the lock; pass `--force-fallback-for` after
  `--` to lock subprojects regardless.

## Examples

### rizin

[rizin](https://github.com/rizinorg/rizin), the reverse-engineering
framework, takes its libraries through Meson wraps: some from WrapDB, some
from git branches. In a checkout of rizin, lock it in a shell with a C
compiler. `-Dregenerate_cmds=disabled` is a rizin option that keeps the
command tables rizin ships, so the lock run needs no PyYAML:

```zsh
git clone --branch v0.8.2 https://github.com/rizinorg/rizin
cd rizin
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' 'nixpkgs#python3' \
  -c nix run github:nix-purifiers/meson-purifier -- lock . -- -Dregenerate_cmds=disabled
```

Then add a `flake.nix` next to `meson.build`:

```nix
{
  inputs.meson-purifier.url = "github:nix-purifiers/meson-purifier";
  inputs.nixpkgs.follows = "meson-purifier/nixpkgs";

  outputs = { nixpkgs, meson-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ meson-purifier.overlays.default ];
      };
      rizin = pkgs.meson-purifier.buildMesonProject {
        pname = "rizin";
        version = "0.8.2";
        src = ./.;
      };
    in
    {
      packages.${system} = rizin.packages // {
        default = rizin.packages.all;
      };
    };
}
```

`git add flake.nix meson-purifier.lock.json`, and the targets of rizin are
packages:

```zsh
nix build '.#rizin'
echo 'mov eax, 1' | nix run '.#rz-asm' -- -a x86 -b 32 -
```

A lockfile committed in the project, as above, is the setup we recommend.
As an option, to package rizin without changing its repository, keep the lockfile in your
own flake. Lock with `--lockfile` pointing into that flake, take rizin as a
flake input, and pass the lockfile to the builder:

```zsh
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' 'nixpkgs#python3' \
  -c nix run github:nix-purifiers/meson-purifier -- \
  lock --lockfile ../my-packages/rizin.lock.json . -- -Dregenerate_cmds=disabled
```

```nix
# rizin.nix in your flake, called with pkgs.callPackage ./rizin.nix { inherit rizin; }
{ meson-purifier, rizin }:
(meson-purifier.buildMesonProject {
  pname = "rizin";
  version = "0.8.2";
  src = rizin;
  lockFile = ./rizin.lock.json;
}).packages.all
```

with rizin as a flake input that is not a flake:

```nix
inputs.rizin = {
  url = "github:rizinorg/rizin/v0.8.2";
  flake = false;
};
```

## Credits

meson-purifier follows sbt-nix-backend, the first of the nix-purifiers: the
tool keeps planning the build, a lock run records what the tool downloads,
Nix builds from the lockfile, and the interactive tool reads the same locked
downloads. The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The package cache is a
`tree` of the [purifier](https://github.com/nix-purifiers/purifier)
library.
