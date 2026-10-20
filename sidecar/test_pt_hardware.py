"""Shared hardware vocabulary and strict build policy checks."""
import pytest
import pkt_builder
import pt_hardware as hardware


def test_catalog_aliases_are_shared():
    assert hardware.MODELS[hardware.identity('4331')]['model'] == 'ISR4331'
    assert hardware.MODELS[hardware.identity('2960')]['model'] == '2960-24TT'
    for cable in hardware.CATALOG['cables']:
        for alias in [cable['id'], *cable['aliases']]:
            assert hardware.cable_for(alias)['id'] == cable['id']
    assert hardware.cable_for('magic cable') is None


@pytest.mark.parametrize('a_type,b_type,expected', [
    ('eSerial', 'eSerial', 'serial'),
    ('eSmartSerial', 'eSerial', 'serial'),
    ('eConsole', 'eRS232', 'console'),
    ('eRS232', 'eConsole', 'console'),
    ('eFiberGigabitEthernet', 'eFiberGigabitEthernet', 'fiber-multi'),
    ('eCopperCoaxial', 'eCopperCoaxial', 'coaxial'),
    ('eCopperEthernet', 'eCopperEthernet', ''),
])
def test_link_cable_is_inferred_from_resolved_ports(a_type, b_type, expected):
    variants = {
        'A': {'ports': [{'name': 'P0', 'type': a_type}]},
        'B': {'ports': [{'name': 'P1', 'type': b_type}]},
    }
    ports = {('A', 'p0'): 'P0', ('B', 'p1'): 'P1'}
    link = {'a': 'A', 'aIf': 'p0', 'b': 'B', 'bIf': 'p1'}
    assert pkt_builder._infer_cable(link, 'A', 'B', ports,
                                    variants) == expected


def test_explicit_cable_wins_over_inference():
    link = {'a': 'A', 'aIf': 'p0', 'b': 'B', 'bIf': 'p1',
            'cable': 'copper-cross'}
    assert pkt_builder._infer_cable(link, 'A', 'B', {}, None) == 'copper-cross'


def test_unresolved_serial_names_still_infer_a_serial_cable():
    link = {'a': 'A', 'aIf': 's0/0/0', 'b': 'B', 'bIf': 'Serial0/0/0'}
    assert pkt_builder._infer_cable(link, 'A', 'B', {}, None) == 'serial'


@pytest.mark.parametrize('cable,port', [('magic cable','GigabitEthernet0/0'), ('copper','GigabitEthernet0/99')])
def test_exact_link_does_not_substitute(cable, port):
    plan={'steps': [
        {'action':'create_nodes','nodes':[
            {'name':n,'type':'router','model':'2911','exactModel':True} for n in ['A','B']]},
        {'action':'create_links','links':[{'a':'A','aIf':port,'b':'B','bIf':'GigabitEthernet0/0','cable':cable,'exactPorts':True}]},
    ]}
    with pytest.raises(pkt_builder.BuildError):
        pkt_builder.build_pkt(plan)


def test_missing_module_is_preserved_as_error():
    with pytest.raises(pkt_builder.BuildError):
        pkt_builder.select_variant(pkt_builder.load_library(),
            {'name':'A','type':'router','model':'2911','modules':['imaginary-module']}, [])
