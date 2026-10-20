"""Recover connector names from PT-authored saves already used by the library.

Only observed names are added. Intrinsic connectors may be absent from the
module PORT tree; those receive index -1 and are never IP-configured.
"""
from pathlib import Path
import collections
import json
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sidecar'))
import pkt_codec
import pkt_template_build as extraction


def refresh():
    file=ROOT/'sidecar/pkt_templates/manifest.json'
    manifest=json.loads(file.read_text(encoding='utf-8'))
    entries={d['key']:d for d in manifest['devices']}
    extraction._TYPE_TO_FAMILY.update({
        'eFiberFastEthernet':'fastethernet', 'eFiberGigabitEthernet':'gigabitethernet',
        'eModem':'modem', 'eCopperCoaxial':'coaxial', 'eUsb':'usb',
    })
    mediums={'ePhoneLine':('eModem','modem'), 'eCoaxial':('eCopperCoaxial','coaxial'),
        'eUsb':('eUsb','usb'), 'eCustomIOLink':('eCustomIO','io'),
        'eConsole':('eConsole','console'), 'eOctal':('eAsync','async')}
    # A model/module key does not encode slot placement. Recover physical
    # interface names from the actual bundled block, never another instance.
    source_cache={}
    for entry in entries.values():
        block=(file.parent/entry['file']).read_bytes()
        types=extraction._device_port_types(block)
        if any('Fiber' in t for t in types):
            path=Path(entry.get('source',''))
            if path.is_file():
                if path not in source_cache:
                    source_cache[path]=pkt_codec.decrypt_pkt(path.read_bytes())
                source_block=next((b for b in extraction.DEVICE_RE.findall(source_cache[path])
                    if extraction._device_name(b)==entry.get('sourceName')
                    and extraction._device_port_types(b)==types),None)
                if source_block is not None: block=source_block
        names=[name for name in extraction._interface_names(block) if '.' not in name]
        inventory,_=extraction.port_inventory(types,names,entry['kind'])
        family_counts=collections.Counter(p['family'] for p in inventory if p['family'])
        named_counts=collections.Counter(extraction._family_of_name(n) for n in names)
        for port in inventory:
            old=next((p for p in entry['ports'] if p['index']==port['index']),None)
            if old is not None and port.get('name') in names and named_counts[port['family']]>=family_counts[port['family']]:
                old.update(port)
                old['namingEvidence']='Bundled PT-authored interface configuration'
    observed=collections.Counter()
    errors=[]
    for source in sorted(([] if '--physical-only' in sys.argv else manifest.get('sources',[])), key=lambda s: 'iot_remote_server' not in s['path']):
        path=Path(source['path'])
        if not path.is_file(): continue
        try: xml=pkt_codec.decrypt_pkt(path.read_bytes())
        except Exception as error:
            errors.append(f'{path.name}: {error}')
            continue
        refs={}
        for ordinal,block in enumerate(extraction.DEVICE_RE.findall(xml)):
            model=extraction._device_model(block) or extraction._one(rb'<TYPE\b[^>]*\bmodel="([^"]*)"',block)
            modules=extraction._device_modules(block)
            key=extraction._safe_key(model+('+'+'+'.join(modules) if modules else ''))
            entry=entries.get(key)
            if entry is None: continue
            saved_refs=re.findall(rb'<SAVE_REF_ID>([^<]+)</SAVE_REF_ID>',block)
            if not saved_refs:
                # Older PT saves identify endpoints by the zero-based DEVICE
                # ordinal; newer saves carry explicit save-ref-id values.
                refs[str(ordinal)]=entry
            for ref in saved_refs:
                value=ref.decode()
                refs[value if value.startswith('save-ref-id:') else 'save-ref-id:'+value]=entry
        for block in extraction.LINK_RE.findall(xml):
            tags=re.findall(rb'<TYPE>([^<]*)</TYPE>',block)
            medium=tags[0].decode() if tags else ''
            observed[medium]+=1
            if medium not in mediums: continue
            text=block.decode('utf-8','replace')
            port_type,family=mediums[medium]
            for side in ['FROM','TO']:
                match=re.search(fr'<{side}>([^<]+)</{side}>\s*<PORT>([^<]+)</PORT>',text)
                if not match or match[1] not in refs: continue
                entry=refs[match[1]]
                name=match[2]
                if any(p.get('name')==name for p in entry['ports']): continue
                endpoint_type,endpoint_family=port_type,family
                if medium=='eOctal' and name.lower().startswith('console'):
                    endpoint_type,endpoint_family='eConsole','console'
                entry['ports'].append(dict(index=-1,type=endpoint_type,family=endpoint_family,name=name,
                    namingEvidence='PT-authored saved cable endpoint'))
    file.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(observedLinks=observed,readErrors=errors,
        evidencePorts=sum(bool(p.get('namingEvidence')) for d in entries.values() for p in d['ports'])),indent=2))


if __name__=='__main__': refresh()
