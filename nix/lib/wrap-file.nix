# SPDX-License-Identifier: MIT
#
# The archives a [wrap-file] wrap downloads, as entries of the purifier
# library, read from the text of the wrap file.
#
# A wrap file is an INI file, which Meson reads with Python's
# configparser (without interpolation), and Nix has no INI reader. This
# file reads the part of that syntax wrap files use, the way configparser
# reads it:
#
#   - `[name]` starts a section; Meson reads the first one, `[wrap-file]`.
#   - `key = value` and `key: value` set a key; the key ends at the first
#     `=` or `:`, keys are lowercased, and whitespace around both is cut.
#   - Lines that start with `#` or `;`, after any indentation, are
#     comments; a `#` later in a line is part of the value.
#   - An indented line continues the value of the key before it, after a
#     newline.
#
# A line it cannot read fails the evaluation, rather than passing a value
# Meson would read differently.
#
# Each archive with a URL becomes an entry: `source_filename` with
# `source_url`, `source_fallback_url` and `source_hash`, and the same
# for `patch_`. The hashes are hexadecimal SHA-256, which Meson checks
# itself and which become Nix's output hashes here. An archive without a
# URL is one the project carries in packagefiles/, which needs no download.
{ lib }:
name: text:
let
  lines = map (lib.removeSuffix "\r") (builtins.filter builtins.isString (builtins.split "\n" text));

  trimEnd = value: lib.head (builtins.match "(.*[^[:space:]])?[[:space:]]*" value);
  orEmpty = value: if value == null then "" else value;

  step =
    state: line:
    let
      blank = builtins.match "[[:space:]]*" line != null;
      comment = builtins.match "[[:space:]]*[#;].*" line;
      continuation = builtins.match "[[:space:]]+([^[:space:]].*)" line;
      header = builtins.match "\\[([^]]*)][[:space:]]*" line;
      setting = builtins.match "([^=:]*[^=:[:space:]])[[:space:]]*[=:][[:space:]]*(.*)" line;
      set =
        key: value:
        state
        // {
          inherit key;
          sections = state.sections // {
            ${state.section} = state.sections.${state.section} // {
              ${key} = value;
            };
          };
        };
    in
    if blank || comment != null then
      state
    else if continuation != null && state.key != null then
      set state.key (
        state.sections.${state.section}.${state.key} + "\n" + orEmpty (trimEnd (lib.head continuation))
      )
    else if header != null then
      state
      // {
        section = lib.head header;
        key = null;
        sections = {
          ${lib.head header} = { };
        }
        // state.sections;
        order = state.order ++ [ (lib.head header) ];
      }
    else if setting != null && state.section != null then
      set (lib.toLower (lib.head setting)) (orEmpty (trimEnd (lib.elemAt setting 1)))
    else
      throw "meson-purifier: cannot read the line `${line}` of the wrap file ${name}";

  parsed = builtins.foldl' step {
    section = null;
    key = null;
    sections = { };
    order = [ ];
  } lines;

  values =
    if parsed.order != [ ] && lib.head parsed.order == "wrap-file" then
      parsed.sections.wrap-file
    else
      throw "meson-purifier: the lockfile lists ${name} as a [wrap-file] wrap, which it is not. Run `meson-purifier lock`.";

  archive =
    what:
    let
      need =
        key: values.${key} or (throw "meson-purifier: the wrap file ${name} has ${what}_url but no ${key}");
    in
    lib.optional (values ? "${what}_url") {
      path = need "${what}_filename";
      url = values."${what}_url";
      mirrors = lib.optional (values ? "${what}_fallback_url") values."${what}_fallback_url";
      hash = builtins.convertHash {
        hash = lib.toLower (need "${what}_hash");
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    };
in
archive "source" ++ archive "patch"
