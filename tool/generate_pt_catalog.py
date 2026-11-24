"""Generate the synchronous Dart catalog from one versioned JSON source.

Refresh device metadata with --refresh from the bundled authentic PT manifest.
Installed template names add recognized entries, never a claim of build support.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sidecar'))
from path_guard import ensure_no_traversal

SOURCE = ROOT / 'assets/packet_tracer/catalog.json'
OUTPUT = ROOT / 'lib/services/packet_tracer/catalog_data.dart'
PYTHON_OUTPUT = ROOT / 'sidecar/pt_catalog_data.py'
KINDS = {
    'Router': 'router', 'Switch': 'switch', 'MultiLayerSwitch': 'switch',
    'Pc': 'pc', 'Laptop': 'laptop', 'Server': 'server', 'Printer': 'printer',
    'AccessPoint': 'wireless', 'LightWeightAccessPoint': 'wireless',
    'WirelessLanController': 'wlc', 'WirelessRouter': 'wireless-router',
    'WirelessRouterNewGeneration': 'wireless-router', 'HomeGateway': 'iot',
    'MCUComponent': 'iot', 'MCU': 'mcu', 'SBC': 'sbc', 'PLC': 'plc',
    'IpPhone': 'phone', 'AnalogPhone': 'analog-phone', 'HomeVoip': 'voip-adapter',
    'Pda': 'smartphone', 'TabletPC': 'tablet', 'CellTower': 'cell-tower',
    'CentralOfficeServer': 'central-office', 'NetworkController': 'controller',
    'Hub': 'hub', 'SecurityAppliance': 'firewall', 'ASA': 'firewall',
    'MerakiServer': 'meraki-server', 'Sniffer': 'sniffer',
    'WiredEndDevice': 'wired-end-device',
    'WirelessEndDevice': 'wireless-end-device',
    'TV': 'tv',
    'Cloud': 'cloud', 'CableModem': 'modem', 'DslModem': 'modem',
    'CoAxialSplitter': 'splitter',
    'DataHistorian': 'historian', 'CyberObserver': 'cyber-observer',
    'Power Distribution Device': 'power-distribution',
}


# The ENGINE's TYPE tag read the way the extractor reads it: regex over the
# <ENGINE> scope, not an XML tree. A block comes from a user-supplied save,
# and a parser that honors internal DTD entity expansion is one more thing a
# hostile file gets to spend memory on.
_TYPE_TAG_RE = re.compile(r'<TYPE\b([^>]*)>([^<]*)</TYPE>')


def _identity_of(text: str) -> tuple[str, str, str] | None:
    engine = re.search(r'<ENGINE>', text)
    if engine:
        end = text.find('</ENGINE>', engine.end())
        text = text[engine.end():end if end >= 0 else len(text)]
    match = _TYPE_TAG_RE.search(text)
    if match is None:
        return None
    attrs = dict(re.findall(r'(\w+)="([^"]*)"', match.group(1)))
    return attrs.get('model', ''), match.group(2).strip(), attrs.get(
        'customModel', '').strip()


def refresh():
    manifest = json.loads((ROOT / 'sidecar/pkt_templates/manifest.json').read_text())
    grouped = {}
    palette_labels = {}
    for device in manifest['devices']:
        model = device['model']
        item = grouped.setdefault(model, dict(model=model,
            type=KINDS.get(device['kind'], device['kind'].lower()),
            kind=device['kind'], aliases=[], variants=[]))
        # The manifest is machine-local but rebuilt from user .pkt saves, so
        # the per-device file name is refused a '..' segment like any other
        # path that did not originate here.
        block = ROOT / 'sidecar/pkt_templates' / ensure_no_traversal(device['file'])
        valid = False
        try:
            identity = _identity_of(block.read_text(encoding='utf-8'))
            fold = lambda s: re.sub('[^a-z0-9]','',s.lower())
            valid = identity is not None and fold(identity[0])==fold(model) and fold(identity[1])==fold(device['kind'])
        except OSError: pass
        if valid:
            item['variants'].append({key: device.get(key, [] if key in ('ports', 'modules') else False)
                for key in ('key', 'modules', 'ports', 'hasConfig')})
            # Packet Tracer's own palette label for this model ('AC' for the
            # Air Conditioner, 'Ceiling Fan' for the Fan). Only a model with a
            # validated real block earns one; kept off the emitted device
            # record, which is why the fold below reads it from this map.
            if identity[2]:
                palette_labels.setdefault(model, identity[2])
    aliases = {
        'ISR4331': ['4331', 'ISR 4331', 'Cisco 4331'],
        'ISR4321': ['4321', 'ISR 4321', 'Cisco 4321'],
        '2960-24TT': ['2960', 'Catalyst 2960'], '2950-24': ['2950'],
        '3560-24PS': ['3560', 'Catalyst 3560', 'layer 3 switch'],
        'WLC-2504': ['2504'], 'WLC-3504': ['3504'],
        'SMARTPHONE-PT': ['Smartphone-PT', 'smartphone'],
        'TabletPC-PT': ['Tablet-PT', 'tablet'],
        'Linksys-WRT300N': ['WRT300N', 'Wireless Router-PT'],
        'DLC100': ['Home Gateway-PT', 'home gateway'],
        'Light': ['smart bulb', 'bulb'], 'Door': ['smart lock'],
        'CoAxialSplitter-PT': ['Coaxial Splitter', 'coaxial splitter',
                               'splitter'],
    }
    for model, values in aliases.items():
        if model in grouped:
            grouped[model]['aliases'] = values
    # Names known to the planner or the installed PT palette, even when this
    # particular library cannot yet produce a valid saved device block.
    extras = {
        'Cloud-PT': ('cloud', ['cloud', 'internet cloud']),
        # The space-named spellings are alias donors: the harvested manifest
        # uses the hyphenated PT model names, and the dedupe below folds the
        # extras entry into it instead of emitting a variant-less duplicate.
        'Cable Modem-PT': ('modem', ['cable modem']),
        'DSL Modem-PT': ('modem', ['dsl modem']),
        'Printer-PT': ('printer', ['printer']),
        'Switch-PT': ('switch', []), 'Switch-PT-Empty': ('switch', []),
        'Router-PT-Empty': ('router', []), 'Repeater-PT': ('repeater', ['repeater']),
        'Bridge-PT': ('bridge', ['bridge']), 'TV-PT': ('tv', ['smart tv']),
        'ASA5505': ('firewall', ['ASA 5505', '5505']),
        'ASA5506': ('firewall', ['ASA 5506', '5506']),
        '2620XM': ('router', []), '2621XM': ('router', []),
        'IoT Server-PT': ('server', ['iot server']),
    }
    for model, (kind, names) in extras.items():
        item = grouped.get(model)
        if item is None:
            grouped[model] = dict(model=model, type=kind, kind=kind,
                aliases=names, variants=[])
        else:
            # The harvested manifest now carries the model; keep the planner's
            # everyday aliases on it instead of losing them to the refresh.
            for alias in names:
                if alias not in item['aliases']:
                    item['aliases'].append(alias)
    # Harvested models arrive under their real Packet Tracer spellings, which
    # can hyphenate a name the planner knows with a space ("DSL-Modem-PT" vs
    # the "DSL Modem-PT" alias). Fold the space-named extras entry into the
    # hyphen-named harvested one instead of emitting a duplicate device.
    for hyphenated, space_named, aliases in (
        ('Cable-Modem-PT', 'Cable Modem-PT', ('Cable Modem-PT', 'cable modem')),
        ('DSL-Modem-PT', 'DSL Modem-PT', ('DSL Modem-PT', 'dsl modem')),
    ):
        if hyphenated in grouped and space_named in grouped:
            extra = grouped.pop(space_named)
            merged = grouped[hyphenated]['aliases']
            for alias in (space_named, *extra['aliases'], *aliases):
                if alias not in merged:
                    merged.append(alias)
    # A PT model may have a marketing alias with another spelling (ASA5505
    # is written as 5505 in native saves). Prefer the real template identity.
    for native, alias in [('5505', 'ASA5505'), ('5506', 'ASA5506'),
                          ('5506-X', 'ASA5506')]:
        if native in grouped and grouped[native]['variants']:
            extra = grouped.pop(alias, None)
            names = [alias, *(extra['aliases'] if extra else [])]
            grouped[native]['aliases'].extend(
                name for name in names if name not in grouped[native]['aliases'])
    installed = Path('C:/Program Files/Cisco Packet Tracer 9.0.0/templates')
    if installed.exists():
        for path in installed.glob('*.ptd'):
            name = path.stem
            if '_' in name or name.startswith(('1841', '2621', '2811', '2960')):
                continue
            grouped.setdefault(name, dict(model=name, type='iot', kind='MCUComponent',
                aliases=[], variants=[]))
    # Packet Tracer labels some models with a name that is not the internal
    # model string: the palette row says 'AC' for the Air Conditioner and
    # 'Ceiling Fan' for the Fan. The installed-template scan adds those rows
    # as recognized-only extras, which would leave the user's exact request
    # resolving to a device the library cannot build. Fold an extra into the
    # buildable model it labels (matched by the block's own customModel).
    for model, item in list(grouped.items()):
        if item['variants']:
            continue
        target = next((g for g in grouped.values()
                       if g['variants'] and palette_labels.get(g['model'], '').lower()
                       == model.lower()), None)
        if target is not None:
            grouped.pop(model)
            names = [model, *item['aliases']]
            target['aliases'].extend(
                name for name in names if name not in target['aliases'])
    cables = [
        ('copper', 'Copper straight-through', ['straight-through', 'straight through', 'straight', 'copper straight-through'], 'eCopper', 'eStraightThrough', ['copper']),
        ('copper-cross', 'Copper crossover', ['crossover', 'cross-over', 'cross over', 'cross', 'copper crossover'], 'eCopper', 'eCrossOver', ['copper']),
        ('console', 'Console / rollover', ['console', 'rollover', 'roll-over', 'console cable'], 'eConsole', '', ['console', 'rs232']),
        ('serial-dce', 'Serial DCE', ['serial dce', 'serial-dce', 'dce'], 'eSerial', '', ['serial']),
        ('serial-dte', 'Serial DTE', ['serial dte', 'serial-dte', 'dte'], 'eSerial', '', ['serial']),
        ('serial', 'Serial', ['serial', 'serial cable'], 'eSerial', '', ['serial']),
        ('fiber-single', 'Fiber single-mode', ['single-mode fiber', 'single mode fiber', 'single-mode fibre', 'single mode fibre', 'single mode', 'single-mode', 'fiber sm', 'smf'], 'eFiber', 'eSingleMode', ['fiber']),
        ('fiber-multi', 'Fiber multimode', ['multimode fiber', 'multi-mode fiber', 'multimode fibre', 'multi mode fiber', 'multimode', 'multi-mode', 'multi mode', 'fiber mm', 'mmf'], 'eFiber', 'eMultiMode', ['fiber']),
        ('fiber', 'Fiber (mode unspecified)', ['fiber', 'fibre', 'fiber optic', 'fibre optic'], 'eFiber', '', ['fiber']),
        ('phone', 'Phone line', ['phone line', 'phone cable', 'telephone cable', 'rj11', 'rj-11', 'telephone'], 'ePhoneLine', '', ['modem']),
        ('coaxial', 'Coaxial', ['coaxial', 'coax', 'coaxial cable'], 'eCoaxial', '', ['coaxial']),
        ('octal', 'Octal', ['octal', 'octal cable'], 'eOctal', '', ['async', 'console']),
        ('ioe', 'IoE custom cable', ['ioe custom cable', 'iot custom cable', 'custom io', 'custom i/o', 'ioe', 'gpio cable'], 'eCustomIOLink', '', ['io']),
        ('usb', 'USB', ['usb', 'usb cable'], 'eUsb', '', ['usb']),
    ]
    source = dict(schema=1, version=manifest['version'],
        provenance='Bundled PT save manifest and installed PT template names; recognition is separate from build verification.',
        devices=sorted(grouped.values(), key=lambda d: d['model'].lower()),
        cables=[dict(id=i, label=label, aliases=aliases, medium=medium,
            variant=variant, families=families,
            templateAvailable=any(l['type']==medium and (not variant or l['cable']==variant) for l in manifest['links']))
            for i, label, aliases, medium, variant, families in cables])
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    SOURCE.write_text(json.dumps(source, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


def generated():
    text = SOURCE.read_text(encoding='utf-8').replace('$', r'\$')
    return "// Generated by tool/generate_pt_catalog.py. Edit catalog.json instead.\nconst ptCatalogJson = r'''" + text + "''';\n"


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.refresh:
        refresh()
    result = generated()
    python_result = '# Generated from assets/packet_tracer/catalog.json.\nimport json\nCATALOG = json.loads(r\'\'\'' + SOURCE.read_text(encoding='utf-8') + '\'\'\')\n'
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding='utf-8') != result or not PYTHON_OUTPUT.exists() or PYTHON_OUTPUT.read_text(encoding='utf-8') != python_result:
            raise SystemExit('Dart catalog is stale: run tool/generate_pt_catalog.py')
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(result, encoding='utf-8')
        PYTHON_OUTPUT.write_text(python_result, encoding='utf-8')
