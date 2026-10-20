import json
import struct
import zlib
import pytest
import pkt_codec as codec
import pt_autopilot as pt


@pytest.mark.parametrize('declared,xml', [(8, b'<' + b'x' * 1000000), (0, b'<x/>'), (100, b'<x/>')], ids=['expanded', 'zero', 'short'])
def test_lying_compressed_sizes_are_refused(declared, xml):
    with pytest.raises(codec.PktFormatError):
        codec._qt_uncompress(struct.pack('>I', declared) + zlib.compress(xml))


def test_valid_compression_and_truncated_stream():
    xml = b'<network/>'
    blob = struct.pack('>I', len(xml)) + zlib.compress(xml)
    assert codec._qt_uncompress(blob) == xml
    with pytest.raises(codec.PktFormatError):
        codec._qt_uncompress(blob[:-2])


def test_privacy_disable_wins_over_an_older_configuration(monkeypatch):
    monkeypatch.setattr(pt, 'LLM', {**pt.LLM, 'configRevision': 0})
    monkeypatch.setattr(pt, 'AUTO_LEARN', {**pt.AUTO_LEARN})
    pt.llm_configure(api_key='old-key', model='model', enabled=True, revision=10, auto_learn=True)
    pt.llm_configure(api_key='', enabled=False, revision=12, auto_learn=False)
    pt.llm_configure(api_key='old-key', enabled=True, revision=11, auto_learn=True)
    assert not pt.LLM['enabled']
    assert pt.LLM['apiKey'] == ''
    assert not pt.AUTO_LEARN['enabled']
    with pytest.raises(RuntimeError):
        pt._llm_request('hello')


def test_local_openai_repair_uses_selected_provider(monkeypatch):
    import urllib.request
    monkeypatch.setattr(pt, 'LLM', {**pt.LLM, 'configRevision': 0})
    pt.llm_configure(api_key='', model='local-model', enabled=True, provider='openai', base_url='http://localhost:1234/v1', revision=1)
    class Response:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self): return json.dumps({'choices': [{'message': {'content': 'replacement'}}]}).encode()
    def send(request, **kwargs):
        assert request.full_url == 'http://localhost:1234/v1/chat/completions'
        assert json.loads(request.data)['model'] == 'local-model'
        return Response()
    monkeypatch.setattr(urllib.request, 'urlopen', send)
    assert pt._llm_request('fix this') == 'replacement'


def test_inflight_response_is_discarded_after_privacy_change(monkeypatch):
    import urllib.request
    monkeypatch.setattr(pt, 'LLM', {**pt.LLM, 'configRevision': 0})
    pt.llm_configure(api_key='key', model='model', enabled=True, revision=1)
    class Response:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self):
            pt.llm_configure(api_key='', enabled=False, revision=2)
            return b'{"candidates":[{"content":{"parts":[{"text":"ignored"}]}}]}'
    monkeypatch.setattr(urllib.request, 'urlopen', lambda *a, **kw: Response())
    with pytest.raises(RuntimeError, match='cancelled'):
        pt._llm_request('hello')
