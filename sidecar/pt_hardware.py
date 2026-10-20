"""Shared versioned Packet Tracer vocabulary and physical media checks."""
import re
from pt_catalog_data import CATALOG


def identity(value):
    return re.sub('[^a-z0-9]','',str(value or '').lower())


MODELS={identity(name):device for device in CATALOG['devices']
        for name in [device['model'],*device['aliases']]}
CABLES={identity(name):cable for cable in CATALOG['cables']
        for name in [cable['id'],cable['label'],*cable['aliases']]}
LINK_MEDIUMS={name.lower():(cable['medium'],cable['variant']) for cable in CATALOG['cables']
        for name in [cable['id'],cable['label'],*cable['aliases']]}


def cable_for(value): return CABLES.get(identity(value or 'copper'))


def port_medium(port):
    text=str(port.get('type','')).lower()
    if 'fiber' in text:return 'fiber'
    if text=='easync':return 'async'
    if 'serial' in text:return 'serial'
    if 'coax' in text:return 'coaxial'
    if 'modem' in text:return 'modem'
    if 'usb' in text:return 'usb'
    if any(word in text for word in ('customio','digital','analog')):return 'io'
    if 'rs232' in text:return 'rs232'
    if 'console' in text:return 'console'
    if 'copper' in text or 'ethernet' in text:return 'copper'
    if not text and port.get('family') in ('ethernet','fastethernet','gigabitethernet'):return 'copper'
    return ''


def single_mode(modules):
    return any(m.upper() in ('GLC-LH-SMD','GLC-LX-SM-RGD') for m in modules)


def suggest_cable(a,b,modules_a=(),modules_b=()):
    """The cable these two ports can actually use, or "" if none can."""
    ma,mb=port_medium(a),port_medium(b)
    pair={ma,mb}
    if ma==mb=='serial':return 'serial'
    if pair=={'console','rs232'}:return 'console'
    if pair=={'async','console'}:return 'octal'
    if ma==mb=='fiber':
        return ('fiber-single' if single_mode(modules_a) and single_mode(modules_b)
                else 'fiber-multi')
    if ma==mb:
        return {'coaxial':'coaxial','usb':'usb','io':'ioe',
                'modem':'phone'}.get(ma,'')
    return ''


def mismatch(cable,a,b,modules_a=(),modules_b=()):
    if not cable:return 'Unknown cable; no substitute was made.'
    if port_medium(a) not in cable['families'] or port_medium(b) not in cable['families']:
        hint=suggest_cable(a,b,modules_a,modules_b)
        suffix=f' Use "{hint}" instead.' if hint and hint!=cable['id'] else ''
        return f"{cable['label']} is incompatible with these connector types.{suffix}"
    if cable['id']=='console' and port_medium(a)==port_medium(b):
        return 'Console requires one RS232 end and one Console end.'
    if cable['id']=='octal' and port_medium(a)==port_medium(b):
        return 'Octal requires one asynchronous end and one Console end.'
    if cable['medium']=='eFiber':
        sm_a,sm_b=single_mode(modules_a),single_mode(modules_b)
        if sm_a!=sm_b:return 'Fiber modules use different optical modes.'
        if cable['id']=='fiber-single' and not sm_a:return 'These modules require multimode fiber.'
        if cable['id']=='fiber-multi' and sm_a:return 'These modules require single-mode fiber.'
    return ''
