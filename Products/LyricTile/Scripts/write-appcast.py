#!/usr/bin/env python3
"""Serialize an owner's real Sparkle signature; never invent or generate a signing key."""
import argparse
import base64
import email.utils
import hashlib
import plistlib
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse

p = argparse.ArgumentParser()
p.add_argument('--archive', type=Path, required=True)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--download-url', required=True)
p.add_argument('--ed-signature', required=True, help='Actual sign_update output for these exact archive bytes')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
url = urlparse(a.download_url)
if url.scheme != 'https' or not url.hostname or url.username or url.password:
    p.error('Download URL must use HTTPS without credentials.')
try:
    if len(base64.b64decode(a.ed_signature, validate=True)) != 64: raise ValueError()
except Exception:
    p.error('A real base64-encoded 64-byte Ed25519 signature is required.')
info = plistlib.loads((a.app/'Contents/Info.plist').read_bytes())
if not info.get('SUPublicEDKey') or not info.get('SUFeedURL'):
    p.error('The actual app must contain the matching public key and feed URL before it is signed/notarized.')
data = a.archive.read_bytes()
if not data: p.error('The actual signed archive is empty.')
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', version='2.0'); channel=ET.SubElement(rss,'channel')
ET.SubElement(channel,'title').text='LyricTile · HOLDSNOW'
ET.SubElement(channel,'link').text=info['SUFeedURL']
item=ET.SubElement(channel,'item')
ET.SubElement(item,'title').text='LyricTile '+info['CFBundleShortVersionString']
ET.SubElement(item,'pubDate').text=email.utils.formatdate(usegmt=True)
ET.SubElement(item,f'{{{ns}}}minimumSystemVersion').text=info['LSMinimumSystemVersion']
ET.SubElement(item,'enclosure', {'url':a.download_url,'length':str(len(data)),
    'type':'application/octet-stream',f'{{{ns}}}version':info['CFBundleVersion'],
    f'{{{ns}}}shortVersionString':info['CFBundleShortVersionString'],f'{{{ns}}}edSignature':a.ed_signature})
ET.indent(rss)
a.output.parent.mkdir(parents=True,exist_ok=True)
ET.ElementTree(rss).write(a.output,encoding='utf-8',xml_declaration=True)
print('Created appcast for exact SHA256:',hashlib.sha256(data).hexdigest())
print('Signature bytes are provided, not independently verified by this serializer. Use Sparkle sign_update/verify and an actual update installation before publication.')
