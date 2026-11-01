# Commands

All from the repository root.

```zsh
# Every check in the sandbox: the conformance checks that need no network,
# the fixture built from its lockfile and run, its packages, release and
# package cache, the wrap file reader, rizin, the command with its unit
# tests, and formatting
nix flake check

# Evaluate the checks for aarch64-linux as well
nix flake check --all-systems --no-build

# The conformance checks that need Nix or the network, and so run outside
# the sandbox, with a C compiler and pkg-config on PATH
nix build '.#toolchain' --out-link toolchain
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' -c tests/lock-run.sh toolchain
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' 'nixpkgs#clang-tools' -c tests/interactive.sh toolchain
nix shell 'nixpkgs#gcc' 'nixpkgs#pkg-config' -c tests/update.sh toolchain

nix fmt
```

After a change to a wrap file or a `meson.build` of a fixture, relock with
`tests/lock-run.sh` and commit the lockfiles it writes; the script fails on
that first run, because the lockfiles changed. It also writes the lockfiles
with faults in `tests/lockfiles/` again, through `tests/negative-locks.py`.
The checks read those as files because `nix flake check --no-build`
evaluates without writing to the store.

## The fixtures

`tests/fixtures/app` takes one dependency from each kind of wrap source:

| Subproject | What it covers |
|---|---|
| `zlib` | a WrapDB `wrap-file` with a source and a patch archive, and fallback URLs, read from the wrap file |
| `inih` | a `wrap-git` at a tag |
| `tinyexpr` | a `wrap-file` with `patch_directory` and `diff_files`, whose patch directory carries a nested wrap |
| `libyaml` | the nested WrapDB wrap that `tinyexpr` carries, which the lockfile records |
| `cjson` | a wrap Meson installs from `subprojects/wrapdb.json` |
| `hghooks` | a `wrap-hg` |
| `svn-examples` | a `wrap-svn` |

Each comes in through `dependency()` and the `[provide]` section of its
wrap. The project itself installs an executable and a static library with
its header, which the lockfile records as its outputs.

`tests/fixtures/external` holds only Meson files, with its lockfile at
`tests/lockfiles/external.lock.json`, for `conformance-external`.
`tests/fixtures/update` pins the WrapDB release 1.3.1-1 of zlib, for
`conformance-update`. `tests/real-world/rizin.lock.json` is the lockfile of
rizin 0.8.2, which `real-world-rizin` builds.

## CI

`.github/workflows/check.yml` runs on every pull request and every push to
main, on x86_64-linux and aarch64-linux. Its `flake-check` job runs
`nix flake check` and evaluates the checks for every system. The jobs
`conformance-relock` (`tests/lock-run.sh`), `conformance-rebuild`
(`nix build --rebuild` of the fixture tests), `conformance-offline`
(`tests/interactive.sh`) and `conformance-update` (`tests/update.sh`) run
the conformance checks that need the network or Nix itself.
