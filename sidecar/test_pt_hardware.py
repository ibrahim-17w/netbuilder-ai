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
