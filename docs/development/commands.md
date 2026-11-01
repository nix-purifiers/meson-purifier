# Commands

All from the repository root.

```zsh
# Every check in the sandbox: the fixture built from its lockfile and run,
# its targets, its package cache, the lockfile checks, the command with its
# unit tests, and formatting
nix flake check

# Evaluate the checks for aarch64-linux as well
nix flake check --all-systems --no-build

# The lock run and the interactive commands, which need Nix or the network
# and so run outside the sandbox, with a C compiler and pkg-config on PATH
nix build '.#toolchain' --out-link toolchain
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' -c tests/lock-run.sh toolchain
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' -c tests/interactive.sh toolchain

nix fmt
```

After a change to a wrap file or a `meson.build` of the fixture, relock it
with `tests/lock-run.sh` and commit the lockfile it writes; the script then
fails on the first run, because the lockfile changed.

## The fixture

`tests/fixtures/app` takes one dependency from each kind of wrap source:

| Subproject | What it covers |
|---|---|
| `zlib` | a WrapDB `wrap-file` with a source and a patch archive, and fallback URLs |
| `inih` | a `wrap-git` at a tag |
| `tinyexpr` | a `wrap-file` with `patch_directory` and `diff_files`, whose patch directory carries a nested wrap |
| `libyaml` | the nested WrapDB wrap that `tinyexpr` carries |
| `cjson` | a wrap Meson installs from `subprojects/wrapdb.json` |
| `hghooks` | a `wrap-hg` |
| `svn-examples` | a `wrap-svn` |

Each comes in through `dependency()` and the `[provide]` section of its
wrap. The project itself installs an executable and a static library with
its header, which the lockfile records as its outputs.

## CI

`.github/workflows/check.yml` runs on every pull request and every push to
main. Its `flake-check` job runs `nix flake check` and evaluates the checks
for every system. Its `outside-the-sandbox` job runs `tests/lock-run.sh`,
which relocks the fixture and fails when the lockfile differs from the
committed one, and `tests/interactive.sh`.
