#!/usr/bin/env python3
"""No-guest live validation of Lumen's host-disk USB hot-plug sequence.

Creates a disposable 64 MiB raw image, attaches it with hdiutil (no mount) to get a
user-owned /dev/diskN, starts a headless qemu-system-aarch64 (-S, no guest OS) with a
second QMP monitor on a private unix socket, and drives exactly what Lumen does
(Sources/Lumen/QEMU/QEMUDevices.swift, Sources/LumenCore/QMPMessages.swift):

  open /dev/rdiskN -> qemu-nbd (fd as stdin, /dev/fd/0) -> blockdev-add nbd
  -> device_add usb-storage -> verify (qom-list, query-block, info usb, a write
  through the USB disk) -> device_del -> DEVICE_DELETED -> blockdev-del
  -> qemu-nbd exits on its own

It also re-checks why Lumen does not use add-fd for disks: QEMU clears O_NONBLOCK on
every SCM_RIGHTS fd with fcntl(F_SETFL); XNU forwards that to the disk driver as
FIONBIO, which fails with ENOTTY, and QEMU drops the monitor connection.

Safety: only ever opens the disk node returned by its own `hdiutil attach`, never
touches a real VM, and detaches and deletes the image when done.
"""
import array
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import tempfile
import time

QEMU = os.environ.get("LUMEN_QEMU", shutil.which("qemu-system-aarch64") or "/opt/homebrew/bin/qemu-system-aarch64")
QEMU_NBD = os.path.join(os.path.dirname(os.path.realpath(QEMU)), "qemu-nbd")
BSD_NAME = re.compile(r"^disk[0-9]+$")
SUN_PATH_MAX = 104
PATTERN = 0xA5
EXPORT = "lumen"


def log(message):
    print(message, flush=True)


def fail(message):
    raise SystemExit(f"FAIL: {message}")


class Closed(Exception):
    pass


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.time() + 10
        while True:
            try:
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.time() > deadline:
                    fail("QMP socket did not appear")
                time.sleep(0.05)
        self.sock.settimeout(10)
        self.buffer = b""
        self.events = []
        self.counter = 0
        greeting = self.read_message()
        if "QMP" not in greeting:
            fail(f"unexpected greeting {greeting}")
        self.version = greeting["QMP"]["version"]["qemu"]
        self.execute("qmp_capabilities")

    def close(self):
        self.sock.close()

    def read_message(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed()
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def execute(self, name, arguments=None, fd=None, allow_error=False):
        self.counter += 1
        ident = f"lumen-{self.counter}"
        message = {"execute": name, "id": ident}
        if arguments is not None:
            message["arguments"] = arguments
        data = (json.dumps(message) + "\n").encode()
        if fd is None:
            self.sock.sendall(data)
        else:
            self.sock.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
        while True:
            reply = self.read_message()
            if "event" in reply:
                self.events.append(reply)
                continue
            if reply.get("id") != ident:
                continue
            if "error" in reply and not allow_error:
                fail(f"{json.dumps(message)} -> {reply['error']}")
            return reply

    def wait_device_deleted(self, device_id, timeout=10):
        deadline = time.time() + timeout
        while True:
            for event in self.events:
                if event["event"] == "DEVICE_DELETED" and event.get("data", {}).get("device") == device_id:
                    self.events.remove(event)
                    return event
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            self.sock.settimeout(remaining)
            try:
                message = self.read_message()
            except socket.timeout:
                return None
            finally:
                self.sock.settimeout(10)
            if "event" in message:
                self.events.append(message)


def lumen_messages(disk, socket_path, read_only):
    """Mirror of QMPMessages.swift / AttachedHostDisk.identifiers(for:)."""
    node, device, serial = f"lumen-hd-{disk}", f"lumen-usb-{disk}", f"LUMEN{disk.upper()}"
    return node, device, {
        "qemu-nbd": [f"--socket={socket_path}", f"--export-name={EXPORT}", "--cache=none", "--discard=ignore",
                     "--image-opts", "driver=host_device,filename=/dev/fd/0"] + (["--read-only"] if read_only else []),
        "blockdev-add": {
            "driver": "nbd", "node-name": node,
            "server": {"type": "unix", "path": socket_path}, "export": EXPORT,
            "read-only": read_only, "auto-read-only": False,
            "cache": {"direct": True, "no-flush": False}, "discard": "ignore",
        },
        "device_add": {"driver": "usb-storage", "id": device, "drive": node, "bus": "usb.0",
                       "removable": True, "serial": serial},
        "device_del": {"id": device},
        "blockdev-del": {"node-name": node},
    }


def probe_add_fd(sock_path, raw_path):
    """Returns True if QEMU accepted a disk fd through add-fd (it does not on macOS/QEMU 11.1)."""
    qmp = QMP(sock_path)
    fd = os.open(raw_path, os.O_RDWR)
    try:
        reply = qmp.execute("add-fd", {"fdset-id": 99}, fd=fd, allow_error=True)
        accepted = "return" in reply
        if accepted:
            qmp.execute("remove-fd", {"fdset-id": 99})
        return accepted, reply
    except Closed:
        return False, "QEMU closed the monitor connection"
    finally:
        os.close(fd)
        qmp.close()


def main():
    for binary in (QEMU, QEMU_NBD):
        if not os.path.exists(binary):
            fail(f"{binary} not found")
    # /tmp keeps socket paths well under Darwin's 104-byte sun_path limit.
    work = tempfile.mkdtemp(prefix="lumen-hotplug-", dir="/tmp")
    os.chmod(work, 0o700)
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work):
    image = os.path.join(work, "stick.img")
    sock_path = os.path.join(work, "qmp.sock")
    nbd_path = os.path.join(work, "nbd.sock")
    if len(nbd_path.encode()) >= SUN_PATH_MAX or len(sock_path.encode()) >= SUN_PATH_MAX:
        fail("socket path too long")
    disk = None
    qemu = None
    nbd = None
    qemu_output = ""
    try:
        log("1. Creating a disposable 64 MiB raw image and attaching it without mounting")
        subprocess.run(["/usr/sbin/mkfile", "-n", "64m", image], check=True)
        out = subprocess.run(["/usr/bin/hdiutil", "attach", "-nomount", "-imagekey",
                              "diskimage-class=CRawDiskImage", image],
                             check=True, capture_output=True, text=True).stdout
        first = out.split()[0] if out.split() else ""
        if not first.startswith("/dev/") or not BSD_NAME.match(first[5:]):
            fail(f"unexpected hdiutil output: {out!r}")
        disk = first[5:]
        raw_path = f"/dev/r{disk}"
        info = os.stat(raw_path)
        if not stat.S_ISCHR(info.st_mode) or info.st_uid != os.getuid():
            fail(f"{raw_path} is not a user-owned character device")
        log(f"   {disk}: {raw_path} is a user-owned character device")

        log("2. Launching headless QEMU (-S, no guest) with a unix-socket QMP monitor")
        qemu = subprocess.Popen([
            QEMU, "-machine", "virt", "-accel", "hvf", "-cpu", "host", "-m", "256",
            "-display", "none", "-nodefaults", "-S",
            "-device", "qemu-xhci,id=usb,p2=8,p3=8",
            "-qmp", f"unix:{sock_path},server=on,wait=off",
        ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

        log("3. Checking add-fd with a disk fd (expected to be rejected on macOS)")
        accepted, detail = probe_add_fd(sock_path, raw_path)
        log(f"   add-fd with {raw_path}: {'accepted' if accepted else 'rejected'} ({detail})")
        if accepted:
            log("   NOTE: this QEMU accepts disk fds via add-fd; the NBD indirection is no longer required")
        if qemu.poll() is not None:
            fail("QEMU exited after the add-fd probe")

        qmp = QMP(sock_path)
        log(f"   reconnected; QEMU {qmp.version['major']}.{qmp.version['minor']}.{qmp.version['micro']}")
        for read_only in (False, True):
            label = "read-only" if read_only else "read-write"
            log(f"4. Attach/detach sequence ({label})")
            node, device, msgs = lumen_messages(disk, nbd_path, read_only)
            fd = os.open(raw_path, os.O_RDONLY if read_only else os.O_RDWR)
            try:
                nbd = subprocess.Popen([QEMU_NBD] + msgs["qemu-nbd"], stdin=fd,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, cwd=work)
            finally:
                os.close(fd)  # qemu-nbd holds its own copy
            deadline = time.time() + 10
            while not os.path.exists(nbd_path):
                if nbd.poll() is not None:
                    fail(f"qemu-nbd exited: {nbd.stderr.read().decode()}")
                if time.time() > deadline:
                    fail("qemu-nbd did not create its socket")
                time.sleep(0.05)
            log(f"   qemu-nbd serving {raw_path} via /dev/fd/0")
            qmp.execute("blockdev-add", msgs["blockdev-add"])
            log("   blockdev-add " + json.dumps(msgs["blockdev-add"]))
            qmp.execute("device_add", msgs["device_add"])
            log("   device_add " + json.dumps(msgs["device_add"]))

            peripherals = [p["name"] for p in qmp.execute("qom-list", {"path": "/machine/peripheral"})["return"]]
            if device not in peripherals:
                fail(f"{device} missing from /machine/peripheral: {peripherals}")
            blocks = [b for b in qmp.execute("query-block")["return"]
                      if b.get("inserted", {}).get("node-name") == node]
            if not blocks:
                fail(f"query-block does not show node {node}")
            inserted = blocks[0]["inserted"]
            if inserted["ro"] != read_only or inserted["image"]["virtual-size"] != 64 << 20:
                fail(f"unexpected block info: {inserted}")
            usb = qmp.execute("human-monitor-command", {"command-line": "info usb"})["return"].strip()
            log(f"   verified: qom /machine/peripheral/{device}; query-block ro={inserted['ro']} "
                f"size={inserted['image']['virtual-size']}; info usb: {usb}")
            # Write through the usb-storage's SCSI disk, i.e. the path the guest uses.
            scsi = f"/machine/peripheral/{device}/{device}.0/legacy[0]"
            value = PATTERN if not read_only else 0x11
            qmp.execute("human-monitor-command",
                        {"command-line": f"qemu-io -d {scsi} \"write -P {value:#x} 0 4096\""})

            qmp.execute("device_del", msgs["device_del"])
            event = qmp.wait_device_deleted(device, timeout=10)
            if event is None:
                fail("DEVICE_DELETED did not arrive within 10 s without a guest")
            log(f"   device_del -> DEVICE_DELETED {event['data']}")
            qmp.execute("blockdev-del", msgs["blockdev-del"])
            log("   blockdev-del -> ok")
            try:
                status = nbd.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fail("qemu-nbd did not exit after QEMU disconnected")
            log(f"   qemu-nbd exited by itself (status {status}), releasing the disk")
            nbd = None

        qmp.execute("quit")
        qemu_output = qemu.communicate(timeout=10)[0].decode(errors="replace")
        qemu = None
    finally:
        for child in (nbd, qemu):
            if child is not None and child.poll() is None:
                child.kill()
                child.wait()
        if disk is not None:
            subprocess.run(["/usr/bin/hdiutil", "detach", f"/dev/{disk}"], capture_output=True)
            log(f"5. Detached /dev/{disk}")
    writes = qemu_output.count("wrote 4096/4096 bytes at offset 0")
    if writes != 1:
        fail(f"expected exactly one successful write (read-write pass only), saw {writes}: {qemu_output!r}")
    with open(image, "rb") as handle:
        head = handle.read(4096)
    if head != bytes([PATTERN]) * 4096:
        fail("the write through the USB disk did not reach the backing device")
    log("6. Read-write pass wrote through to the device; read-only pass refused its write")
    log("PASS: host-disk USB hot-plug sequence works on this QEMU")


if __name__ == "__main__":
    main()
