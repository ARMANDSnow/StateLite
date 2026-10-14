#!/usr/bin/env python3
"""Validate a StateLite release without executing the app/helper or accessing SMC."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import zipfile


# Keep aligned with slsHardened in Sources/FanService.c.
FORBIDDEN_ENTITLEMENTS = (
    'com.apple.security.cs.allow-dyld-environment-variables',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.get-task-allow',
    'get-task-allow',
    'com.apple.security.cs.allow-unsigned-executable-memory',
    'com.apple.security.cs.disable-executable-page-protection',
    'com.apple.security.cs.allow-jit',
)


def version_from_plist(path, tag=None):
    info = plistlib.loads(pathlib.Path(path).read_bytes())
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Release version must be X.Y.Z')
    if tag is not None and tag != 'v' + version:
        raise ValueError('Tag does not match CFBundleShortVersionString')
    if info.get('LSMinimumSystemVersion') != '14.0':
        raise ValueError('Expected macOS 14.0 deployment minimum')
    return version


def validate_zip(path, app):
    app = pathlib.Path(app)
    expected = {p.relative_to(app.parent).as_posix(): p for p in app.rglob('*') if p.is_file()}
    with zipfile.ZipFile(path) as archive:
        seen = set()
        for item in archive.infolist():
            name = item.filename
            if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts:
                raise ValueError('Unsafe ZIP path')
            if name in seen:
                raise ValueError('Duplicate ZIP member')
            seen.add(name)
            if item.is_dir():
                if not name.startswith('StateLite.app/'):
                    raise ValueError('Unexpected ZIP directory')
                continue
            if name not in expected or archive.read(item) != expected[name].read_bytes():
                raise ValueError('ZIP does not exactly match the signed app')
        if {x for x in seen if not x.endswith('/')} != set(expected):
            raise ValueError('ZIP missing app files')


def command(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout


def validate_signature_metadata(output, entitlements):
    flags = re.search(r'^CodeDirectory\b.*\bflags=0x([0-9a-fA-F]+)', output, re.M)
    if not flags or not int(flags[1], 16) & 0x10000:
        raise ValueError('Signature must enable hardened runtime')
    if not isinstance(entitlements, dict):
        raise ValueError('Signature entitlements must be a dictionary')
    for name in FORBIDDEN_ENTITLEMENTS:
        if name in entitlements and entitlements[name] is not False:
            raise ValueError(f'Forbidden runtime exception: {name}')
    match = re.search(r'^CDHash=([0-9a-f]+)$', output, re.M)
    if not match:
        raise ValueError('Missing code signature CDHash')
    kind = 'adhoc' if 'Signature=adhoc' in output else 'developer-id'
    if kind == 'developer-id' and 'Authority=Developer ID Application:' not in output:
        raise ValueError('Public signed releases require a Developer ID Application identity')
    return {'cdhash': match[1], 'kind': kind, 'hardenedRuntime': True}


def signature(path):
    command('codesign', '--verify', '--strict', str(path))
    output = command('codesign', '-d', '--verbose=4', str(path))
    # codesign writes diagnostics to stderr; parse only the XML stdout payload.
    displayed = subprocess.run(
        ['codesign', '--display', '--entitlements', '-', '--xml', str(path)],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    entitlements = plistlib.loads(displayed) if displayed.strip() else {}
    return validate_signature_metadata(output, entitlements)


def notarization(path):
    # A missing/invalid ticket or unavailable verifier proves only non-verification.
    try:
        result = subprocess.run(
            ['xcrun', 'stapler', 'validate', str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 'not-verified'
    return 'stapled-valid' if result.returncode == 0 else 'not-verified'


def source_state():
    root = pathlib.Path(__file__).resolve().parents[1]
    try:
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip())
        return {'sourceCommit': commit, 'sourceDirty': dirty}
    except (OSError, subprocess.CalledProcessError):
        return {'sourceCommit': None, 'sourceDirty': None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--plist', required=True)
    parser.add_argument('--tag')
    parser.add_argument('--app')
    parser.add_argument('--zip')
    parser.add_argument('--metadata')
    parser.add_argument('--checksums')
    args = parser.parse_args()
    version = version_from_plist(args.plist, args.tag)
    if not args.app:
        print(version)
        return
    app = pathlib.Path(args.app)
    if version_from_plist(app / 'Contents/Info.plist') != version:
        raise ValueError('Built app version differs')
    signatures = {}
    for name in ('StateLite', 'FanHelper'):
        binary = app / 'Contents/MacOS' / name
        if command('lipo', '-archs', str(binary)).strip() != 'arm64':
            raise ValueError('Release must contain only arm64')
        signatures[name] = signature(binary)
    signature(app)
    main_hash = command('python3', str(pathlib.Path(__file__).with_name('hash-executable.py')), str(app / 'Contents/MacOS/StateLite')).strip()
    if main_hash.encode() not in (app / 'Contents/MacOS/FanHelper').read_bytes():
        raise ValueError('Helper is not paired with this main executable')
    result = {'version': version, 'architecture': 'arm64', 'minimumMacOS': '14.0', 'signatures': signatures, 'mainSectionSHA256': main_hash, 'notarization': notarization(app)}
    result.update(source_state())
    if args.zip:
        if pathlib.Path(args.zip).name != f'StateLite-v{version}-macos-arm64.zip':
            raise ValueError('Unexpected public artifact name')
        validate_zip(args.zip, app)
        digest = hashlib.sha256(pathlib.Path(args.zip).read_bytes()).hexdigest()
        result['zipSHA256'] = digest
        if args.checksums:
            pathlib.Path(args.checksums).write_text(f'{digest}  {pathlib.Path(args.zip).name}\n')
    if args.metadata:
        pathlib.Path(args.metadata).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
