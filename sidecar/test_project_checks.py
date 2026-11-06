from pt_verify import derive_tests, shape_results


def test_saved_checks_use_live_ping_but_denials_stay_manual():
    plan = {'nodes': [{'name': 'PC1', 'type': 'pc'}, {'name': 'R1', 'type': 'router'}],
            'customChecks': [
                {'id': 'allow', 'source': 'PC1', 'destination': 'R1', 'kind': 'ping', 'allow': True},
                {'id': 'deny', 'source': 'PC1', 'destination': 'R1', 'kind': 'ping', 'allow': False},
                {'id': 'bad', 'source': 'missing', 'destination': 'R1', 'kind': 'ping', 'allow': True}]}
    tests = derive_tests(plan)
    by_id = {t.get('checkId'): t for t in tests}
    assert by_id['allow']['kind'] == 'ping'
    assert by_id['deny']['kind'] == 'manual'
    assert 'bad' not in by_id
    results = shape_results([{'src': 'PC1', 'target': 'R1', 'ok': False}], tests)
    assert next(t for t in results if t.get('checkId') == 'deny')['status'] == 'manual'


def test_no_live_evidence_never_passes():
    tests = [{'checkId': 'a', 'src': 'PC1', 'dst': 'PC2', 'kind': 'ping'}]
    assert shape_results([], tests)[0]['status'] == 'skipped'
