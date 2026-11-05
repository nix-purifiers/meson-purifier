# SPDX-License-Identifier: MIT
{ pkgs, build }:
let
  built = build {
    src = ./fixtures/resource-schema;
    pname = "schema-bundle";
    version = "1.0.0";
    resourceRoots."." = "share/schemas";
    resourceSchema = {
      format = "thrift";
      entrypoints = [ "main.thrift" ];
    };
  };
  view = built.projections.resources;
  python = pkgs.python3.withPackages (p: [ p.thrift ]);
in
assert built.fetches == [ ];
assert !(built.projections ? native);
pkgs.runCommand "installed-schema-ordinary-consumers"
  {
    nativeBuildInputs = [
      python
      pkgs.thrift
    ];
  }
  ''
    test -e ${
      import ./resource-consumer.nix {
        inherit pkgs;
        projection = view;
      }
    }
    mkdir generated
    thrift -r --gen py -I ${view.directory} -out generated ${view.directory}/main.thrift
    PYTHONPATH=generated python - <<'PY'
    import json
    from main_value.ttypes import Envelope
    from common_value.ttypes import Value
    from thrift.transport.TTransport import TMemoryBuffer
    from thrift.protocol.TBinaryProtocol import TBinaryProtocol
    catalog = json.load(open('${view.catalog}'))
    assert catalog['schema'] == {'format': 'thrift', 'entrypoints': ['main.thrift']}
    assert set(catalog['files']) == {'main.thrift', 'common/value.thrift'}
    buffer = TMemoryBuffer()
    Envelope(value=Value(answer=42)).write(TBinaryProtocol(buffer))
    restored = Envelope()
    restored.read(TBinaryProtocol(TMemoryBuffer(buffer.getvalue())))
    assert restored.value.answer == 42
    PY
    touch $out
  ''
