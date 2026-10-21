#!/usr/bin/env python3
"""Build a compact ARM64 driver disc from the official, versioned VirtIO ISO.

Reads ISO9660/Joliet directories using HTTPS ranges, then fetches only selected
ARM64 files. Never executes downloaded files or changes Windows signing policy.
"""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import struct
import subprocess
import tempfile

SOURCE = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"
ROOT = pathlib.Path(__file__).resolve().parent.parent


class RemoteISO:
    def __init__(self, source, metadata):
        self.source = source
        self.metadata = metadata
        self.cache = {}
        self.joliet = False
        self.block = 2048
        root = None
        for sector in range(16, 48):
            data = self.read(sector * 2048, 2048)
            if data[1:6] != b"CD001":
                raise ValueError("Invalid ISO volume descriptor")
            if data[0] == 1:
                root = data[156:190]
                self.block = struct.unpack_from("<H", data, 128)[0]
            if data[0] == 2 and data[88:91] in (b"%/@", b"%/C", b"%/E"):
                root = data[156:190]
                self.joliet = True
                break
            if data[0] == 255:
                break
        if root is None or self.block != 2048:
            raise ValueError("Missing supported ISO directory")
        self.root = self.entry(root)

    def read(self, offset, length):
        if (offset, length) in self.cache:
            return self.cache[(offset, length)]
        if not 0 < length <= 32 * 1024 * 1024:
            raise ValueError("Unexpected ISO extent size")
        if self.metadata and offset + length <= self.metadata.stat().st_size:
            with self.metadata.open("rb") as handle:
                handle.seek(offset)
                return handle.read(length)
        with tempfile.TemporaryDirectory(prefix="lumen-driver-range-") as temp:
            output = pathlib.Path(temp) / "data"
            headers = pathlib.Path(temp) / "headers"
            subprocess.run(["curl", "--silent", "--show-error", "--fail", "--proto", "=https",
                            "--retry", "2", "--retry-delay", "1", "--max-time", "180",
                            "--max-filesize", str(length),
                            "--range", f"{offset}-{offset + length - 1}",
                            "--dump-header", str(headers), "--output", str(output), self.source], check=True)
            response = headers.read_text().lower()
            if f"content-range: bytes {offset}-{offset + length - 1}/" not in response:
                raise ValueError("Server did not honor the requested HTTPS byte range")
            data = output.read_bytes()
            if len(data) != length:
                raise ValueError("Incomplete driver extent")
            self.cache[(offset, length)] = data
            return data

    def entry(self, record):
        name = record[33:33 + record[32]]
        if name in (b"\x00", b"\x01"):
            decoded = "." if name == b"\x00" else ".."
        else:
            decoded = name.decode("utf-16-be" if self.joliet else "ascii").split(";")[0]
        return (decoded, struct.unpack_from("<I", record, 2)[0] * self.block,
                struct.unpack_from("<I", record, 10)[0], bool(record[25] & 2))

    def children(self, entry):
        data = self.read(entry[1], entry[2])
        result, offset = [], 0
        while offset < len(data):
            size = data[offset]
            if size == 0:
                offset = (offset // self.block + 1) * self.block
                continue
            if size < 34 or offset + size > len(data):
                raise ValueError("Malformed driver directory")
            child = self.entry(data[offset:offset + size])
            if child[0] not in (".", ".."):
                if any(char in child[0] for char in "/\\\x00"):
                    raise ValueError("Unsafe driver filename")
                result.append(child)
            offset += size
        return result

    def find(self, path):
        entry = self.root
        for name in path.split("/"):
            entry = next((child for child in self.children(entry) if child[0].lower() == name.lower()), None)
            if entry is None:
                raise ValueError(f"Missing driver directory: {path}")
        return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=pathlib.Path, help="Optional local ISO or downloaded prefix for directory reads")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".runtime/WindowsDrivers.iso")
    args = parser.parse_args()
    iso = RemoteISO(SOURCE, args.metadata)
    requested = []
    for driver in ("NetKVM", "viogpudo", "Balloon", "vioserial", "vioinput", "viorng", "vioscsi", "viostor"):
        directory = f"{driver}/w11/ARM64"
        for entry in iso.children(iso.find(directory)):
            if not entry[3] and not entry[0].lower().endswith(".pdb"):
                requested.append((f"{directory}/{entry[0]}", entry))
    # Include the publisher's root licensing and source notices, where present.
    for entry in iso.children(iso.root):
        if not entry[3] and any(word in entry[0].lower() for word in ("license", "copying", "notice")):
            requested.append((entry[0], entry))
    print(f"Fetching {len(requested)} ARM64 driver files ({sum(e[2] for _, e in requested) / 1048576:.1f} MiB)", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lumen-arm64-drivers-", dir=args.output.parent) as temp:
        staging = pathlib.Path(temp)

        def fetch(item):
            path, entry = item
            data = iso.read(entry[1], entry[2])
            if path.lower().endswith((".sys", ".exe", ".dll")):
                if data[:2] != b"MZ":
                    raise ValueError(f"Not a PE executable: {path}")
                pe = struct.unpack_from("<I", data, 60)[0]
                if data[pe:pe + 4] != b"PE\x00\x00" or struct.unpack_from("<H", data, pe + 4)[0] != 0xAA64:
                    raise ValueError(f"Not an ARM64 executable: {path}")
            destination = staging / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            print(f"Fetched {path}", flush=True)
            return {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            manifest = list(pool.map(fetch, requested))
        (staging / "Lumen-driver-provenance.json").write_text(json.dumps({"source": SOURCE, "files": manifest}, indent=2))
        (staging / "README-Lumen.txt").write_text(
            "VirtIO Windows ARM64 drivers, version 0.1.302, from the official Fedora-hosted distribution.\n"
            "Source and licenses: https://github.com/virtio-win/kvm-guest-drivers-windows\n"
            "Run install-drivers.cmd as administrator from the LUMENSETUP disc.\n"
            "Windows must accept the original publisher signatures. Lumen never enables test signing.\n")
        # Publish only a complete disc, keeping a previous known-good disc if fetching fails.
        target = args.output.with_name(args.output.stem + ".partial.iso")
        try:
            subprocess.run(["hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "LUMENDRIVERS",
                            "-o", str(target), str(staging)], check=True)
            target.replace(args.output)
        finally:
            target.unlink(missing_ok=True)
    print(f"Prepared {args.output}")


if __name__ == "__main__":
    main()
