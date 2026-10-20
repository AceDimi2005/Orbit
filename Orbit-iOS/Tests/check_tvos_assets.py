"""Check Apple's required tvOS icon/Top Shelf assets, optionally in an archive.

python3 Orbit-iOS/Tests/check_tvos_assets.py --app path/to/OrbitTV.app
No App Store account, signing operation or upload is performed.
"""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / 'Orbit-iOS/OrbitTV/Assets.xcassets'
BRAND = CATALOG / 'AppIcon.brandassets'
REQUIRED_IMAGES = {
    'Top Shelf Image': {(1920, 720, 1), (3840, 1440, 2)},
    'Top Shelf Image Wide': {(2320, 720, 1), (4640, 1440, 2)},
}

def read_json(path):
    return json.loads(path.read_text())

def png_info(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'Invalid PNG: {path}'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    assert depth == 8, f'Use an 8-bit image: {path}'
    return width, height, color

def verify_plist(info):
    assert info['CFBundleIcons']['CFBundlePrimaryIcon'] == 'App Icon', 'Missing tvOS primary icon'
    shelf = info['TVTopShelfImage']
    assert shelf['TVTopShelfPrimaryImage'] == 'Top Shelf Image'
    assert shelf['TVTopShelfPrimaryImageWide'] == 'Top Shelf Image Wide', 'Missing wide Top Shelf image'

source_info = plistlib.loads((ROOT / 'Orbit-iOS/OrbitTV/Info.plist').read_bytes())
verify_plist(source_info)
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Orbit-iOS/Orbit.xcodeproj/project.pbxproj')
]))['objects']
configs = [obj['buildSettings'] for obj in project.values()
           if obj.get('isa') == 'XCBuildConfiguration'
           and obj.get('buildSettings', {}).get('INFOPLIST_FILE') == 'OrbitTV/Info.plist']
assert len(configs) == 2
assert all(c['ASSETCATALOG_COMPILER_APPICON_NAME'] == 'AppIcon' for c in configs)

assets = read_json(BRAND / 'Contents.json')['assets']
for asset in assets:
    directory = BRAND / asset['filename']
    width, height = map(int, asset['size'].split('x'))
    if asset['role'] == 'primary-app-icon':
        layers = read_json(directory / 'Contents.json')['layers']
        assert len(layers) >= 2, 'tvOS parallax icons require at least two image layers'
        for layer in layers:
            image_set = directory / layer['filename'] / 'Content.imageset'
            for image in read_json(image_set / 'Contents.json')['images']:
                scale = int(image['scale'][0])
                w, h, color = png_info(image_set / image['filename'])
                assert (w, h) == (width * scale, height * scale)
                if layer == layers[-1]:
                    assert color == 2, 'The bottom icon layer must be opaque RGB'
    else:
        name = directory.stem
        actual = set()
        for image in read_json(directory / 'Contents.json')['images']:
            w, h, color = png_info(directory / image['filename'])
            assert color == 2, 'Top Shelf images must be opaque RGB'
            actual.add((w, h, int(image['scale'][0])))
        assert actual == REQUIRED_IMAGES[name], f'Incorrect Top Shelf dimensions: {name}'
assert {a['role'] for a in assets} >= {'primary-app-icon', 'top-shelf-image', 'top-shelf-image-wide'}
assert {a['size'] for a in assets if a['role'] == 'primary-app-icon'} >= {'1280x768', '400x240'}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path)
args = parser.parse_args()
if args.app:
    app_info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    verify_plist(app_info)
    assert app_info['CFBundleSupportedPlatforms'] == ['AppleTVOS']
    assert app_info['UIDeviceFamily'] == [3]
    renditions = json.loads(subprocess.check_output(['xcrun', 'assetutil', '--info', str(args.app / 'Assets.car')]))
    assert any(a.get('Name') == 'App Icon' and a.get('AssetType') == 'ImageStack' for a in renditions)
    for name, dimensions in REQUIRED_IMAGES.items():
        actual = {(a.get('PixelWidth'), a.get('PixelHeight'), a.get('Scale'))
                  for a in renditions if a.get('Name') == name and a.get('AssetType') == 'Image'}
        assert actual >= dimensions, f'Archive omitted a required Top Shelf rendition: {name}'
    print(f"PASS: tvOS archive build {app_info['CFBundleVersion']} contains the required icon/Top Shelf keys and compiled images")
else:
    print('PASS: tvOS Debug/Release icon selection, layered App Store/Home icons, opaque 1x/2x Top Shelf images and Info.plist keys')
