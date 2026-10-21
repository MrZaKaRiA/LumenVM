#!/usr/bin/env python3
"""Extract the pinned upstream ARM64 clipboard agent without installing UTM drivers."""
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = 'https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/utm-guest-tools-0.1.273.exe'
ARCHIVE_HASH = '82de73050d983361e8c9294d384871c0debaaa74a3290d971e0556e230b134ca'
FILES = {
    'vdagent.exe': 'cc5167af34bf5d6dc594e85d0c309af64c1e22b9f1297a5ef69ca99a403c479a',
    'vdservice.exe': '4862a0ecd865c3f9ede015df4639ab97a4a166a0580e0644ab2f42052b629060',
}
LICENSE_HASH = 'd8c320ffc0030d1b096ae4732b50d2b811cf95e9a9b7377c1127b2563e0a0388'

def verified(path, digest):
    return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest

def main():
    target = ROOT / '.runtime/WindowsClipboard'
    if all(verified(target / name, digest) for name, digest in {**FILES, 'COPYING': LICENSE_HASH}.items()):
        print('ARM64 clipboard agents verified.'); return
    archive = ROOT / 'build/guest-tools-extracted/utm-guest-tools.exe'
    if not verified(archive, ARCHIVE_HASH):
        archive.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['curl', '--location', '--fail', '--show-error', '--proto', '=https',
                        '--max-time', '600', '--output', str(archive), SOURCE], check=True)
        if not verified(archive, ARCHIVE_HASH):
            raise ValueError('Guest tools archive SHA-256 mismatch')
    sevenzip = shutil.which('7zz')
    if not sevenzip:
        raise RuntimeError('Install sevenzip with Homebrew to extract the ARM64 guest tools.')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lumen-clipboard-', dir=target.parent) as tmp:
        stage = pathlib.Path(tmp)
        for name, digest in FILES.items():
            data = subprocess.check_output([sevenzip, 'x', '-so', str(archive), 'ARM64/' + name])
            pe = struct.unpack_from('<I', data, 60)[0]
            if hashlib.sha256(data).hexdigest() != digest or data[:2] != b'MZ' or data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, pe+4)[0] != 0xAA64:
                raise ValueError('Invalid ARM64 clipboard agent: ' + name)
            (stage / name).write_bytes(data)
        license_file = ROOT / 'build/vdagent-COPYING'
        if not verified(license_file, LICENSE_HASH):
            subprocess.run(['curl', '--fail', '--show-error', '--proto', '=https', '--max-time', '60',
                            '--output', str(license_file), 'https://raw.githubusercontent.com/nefarius/vd_agent/master/COPYING'], check=True)
        if not verified(license_file, LICENSE_HASH):
            raise ValueError('Clipboard agent license SHA-256 mismatch')
        shutil.copyfile(license_file, stage / 'COPYING')
        (stage / 'provenance.json').write_text(json.dumps({'source': SOURCE, 'archiveSHA256': ARCHIVE_HASH,
            'files': FILES, 'license': 'GPL-2.0-or-later',
            'sourceCode': 'https://gitlab.freedesktop.org/spice/win32/vd_agent',
            'note': 'Unmodified upstream ARM64 binaries; hash verified, not Authenticode signed.'}, indent=2))
        target.mkdir(exist_ok=True)
        for path in stage.iterdir():
            shutil.copyfile(path, target / path.name)
    print('Prepared ARM64 clipboard agents (575 KiB).')

if __name__ == '__main__': main()
