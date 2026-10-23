#!/usr/bin/env python3
"""Disposable Linux ext4 write/delete/fstrim test for QEMU/NVMe and Apple/Virtio.

Requires a Void-compatible ARM64 live ISO (boot/vmlinux, boot/initrd and
LiveOS/squashfs.img containing LiveOS/rootfs.img), sevenzip and e2fsprogs.
Never opens a real VM disk, enables networking or exposes host folders.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
INIT = r'''#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
fail() { echo "LUMEN_TEST_ERROR: $*"; sync; echo o > /proc/sysrq-trigger; exit 1; }
for m in virtio_pci virtio_blk nvme ext4 loop iso9660 squashfs; do modprobe "$m" || true; done
mkdir -p /test /media/iso /media/squash /media/root
for attempt in 1 2 3 4 5; do
  media=''
  for d in /dev/vdb /dev/vda /dev/vdc; do
    if mount -t iso9660 -o ro "$d" /media/iso 2>/dev/null; then media="$d"; break; fi
  done
  [ -n "$media" ] && break
  sleep 1
done
[ -n "$media" ] || fail 'live ISO not found'
mount -t squashfs -o loop,ro /media/iso/LiveOS/squashfs.img /media/squash || fail squashfs
mount -t ext4 -o loop,ro,noload /media/squash/LiveOS/rootfs.img /media/root || fail rootfs
disk=/dev/nvme0n1
[ -b "$disk" ] || disk=/dev/vda
mount -t ext4 -o nodiscard "$disk" /test || fail 'scratch mount'
printf 'LUMEN-STORAGE-SENTINEL\n' > /test/keep.txt
sync
echo LUMEN_STAGE_BASELINE
read -r continue
dd if=/dev/urandom of=/test/payload bs=1048576 count=128 || fail write
sync
echo LUMEN_STAGE_WRITTEN
read -r continue
rm /test/payload || fail delete
sync
echo LUMEN_STAGE_DELETED
read -r continue
/media/root/usr/bin/fstrim -v /test
trim_status=$?
echo "LUMEN_TRIM_EXIT=$trim_status"
sync
echo LUMEN_STAGE_TRIMMED
read -r continue
[ "$(cat /test/keep.txt)" = LUMEN-STORAGE-SENTINEL ] || fail 'sentinel changed'
umount /test || fail unmount
echo LUMEN_TEST_COMPLETE
sync
poweroff -f
echo o > /proc/sysrq-trigger
'''


def cpio_file(name, data, mode=0o100755):
    name = name.encode() + b'\0'
    header = ('070701' + ''.join(f'{n:08x}' for n in [1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name), 0])).encode()
    prefix = header + name
    return prefix + b'\0' * (-len(prefix) % 4) + data + b'\0' * (-len(data) % 4)


def run_guest(command, disk, log):
    stages = ['BASELINE', 'WRITTEN', 'DELETED', 'TRIMMED']
    samples = {}
    content = bytearray()
    console_log = log.open('wb')
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 180
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    break
                content.extend(data)
                console_log.write(data)
                console_log.flush()
                if b'LUMEN_TEST_ERROR:' in content:
                    raise RuntimeError('Guest storage test failed; inspect its console log')
                for stage in stages:
                    if stage not in samples and ('LUMEN_STAGE_' + stage).encode() in content:
                        info = disk.stat()
                        samples[stage] = {'capacityBytes': info.st_size, 'allocatedBytes': info.st_blocks * 512}
                        process.stdin.write(b'\n')
                        process.stdin.flush()
            if process.poll() is not None:
                break
        else:
            raise TimeoutError('Disposable storage guest exceeded 180 seconds')
        if process.poll() is None:
            process.wait(timeout=10)
        if process.returncode != 0 or b'LUMEN_TEST_COMPLETE' not in content or len(samples) != 4:
            raise RuntimeError('Disposable guest did not complete all storage stages')
        assert all(s['capacityBytes'] == 512 * 1_048_576 for s in samples.values())
        assert samples['WRITTEN']['allocatedBytes'] - samples['BASELINE']['allocatedBytes'] >= 120 * 1_048_576
        return {'samples': samples, 'trimAccepted': b'LUMEN_TRIM_EXIT=0' in content,
                'allocationDecreasedAfterTrim': samples['TRIMMED']['allocatedBytes'] < samples['DELETED']['allocatedBytes'],
                'sentinelPreserved': True}
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        selector.close()
        console_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iso', required=True, type=Path)
    parser.add_argument('--backend', choices=['qemu', 'apple', 'both'], default='both')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/storage-trim-report.json')
    args = parser.parse_args()
    iso = args.iso.resolve(strict=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sevenzip = shutil.which('7zz')
    mkfs = Path('/opt/homebrew/opt/e2fsprogs/sbin/mke2fs')
    if not sevenzip or not mkfs.is_file(): raise RuntimeError('Install sevenzip and e2fsprogs with Homebrew')
    report = {'guest': 'Void-compatible ARM64 live media, ext4 scratch filesystem', 'payloadBytes': 128 * 1_048_576,
              'host': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(), 'backends': {}}
    with tempfile.TemporaryDirectory(prefix='lumen-storage-', dir=args.output.parent) as temporary:
        temp = Path(temporary)
        kernel, initrd = temp / 'kernel', temp / 'initrd'
        for member, target in [('boot/vmlinux', kernel), ('boot/initrd', initrd)]:
            with target.open('xb') as output:
                subprocess.run([sevenzip, 'x', '-so', str(iso), member], stdout=output, check=True)
        with initrd.open('ab') as output:
            output.write(b'\0' * (-output.tell() % 4))
            output.write(cpio_file('lumen-storage-init', INIT.encode()) + cpio_file('TRAILER!!!', b'', 0))
        helper = temp / 'storage-trim-host'
        if args.backend in ['apple', 'both']:
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-framework', 'Virtualization',
                            str(ROOT / 'scripts/storage-trim-host.swift'), '-o', str(helper)], check=True)
            subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'Resources/Lumen.entitlements'), str(helper)], check=True)
        for backend in (['qemu', 'apple'] if args.backend == 'both' else [args.backend]):
            disk = temp / (backend + '-scratch.img')
            with disk.open('xb') as image: image.truncate(512 * 1_048_576)
            subprocess.run([str(mkfs), '-q', '-F', '-t', 'ext4', '-E', 'lazy_itable_init=0,lazy_journal_init=0', str(disk)], check=True)
            if backend == 'qemu':
                # Match Lumen's raw file, discard, zero detection, balanced cache and NVMe device.
                block = {'driver': 'raw', 'node-name': 'disk', 'read-only': False, 'discard': 'unmap',
                         'detect-zeroes': 'unmap', 'cache': {'direct': False, 'no-flush': False},
                         'file': {'driver': 'file', 'filename': str(disk)}}
                command = ['qemu-system-aarch64', '-machine', 'virt,highmem=on,gic-version=3', '-accel', 'hvf',
                           '-cpu', 'host', '-smp', '2', '-m', '2048', '-display', 'none', '-monitor', 'none',
                           '-serial', 'stdio', '-nic', 'none', '-nodefaults', '-no-user-config',
                           '-kernel', str(kernel), '-initrd', str(initrd), '-append', 'console=ttyAMA0 rdinit=/lumen-storage-init panic=1',
                           '-blockdev', json.dumps(block), '-device', 'nvme,drive=disk,serial=LUMEN_STORAGE_TEST',
                           '-blockdev', json.dumps({'driver': 'raw', 'node-name': 'media', 'read-only': True,
                                                   'file': {'driver': 'file', 'filename': str(iso)}}),
                           '-device', 'virtio-blk-pci,drive=media']
            else:
                command = [str(helper), str(kernel), str(initrd), str(disk), str(iso)]
            print('Testing', backend, flush=True)
            log = args.output.with_name(args.output.stem + '-' + backend + '.log')
            report['backends'][backend] = run_guest(command, disk, log)
            args.output.write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report['backends'][backend], indent=2), flush=True)
    print('Scratch guests/disks removed; report:', args.output)


if __name__ == '__main__': main()
