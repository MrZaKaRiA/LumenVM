"""Private per-VM SMB transport. Never enables macOS File Sharing."""
import hashlib
import hmac
import json
import logging
import os
import secrets
import sys
import threading
import time
from pathlib import Path

# -I ignores PYTHONPATH; only load the runtime shipped beside this script.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from impacket import smb, smb3structs as smb2, smbserver
from impacket.nt_errors import STATUS_ACCESS_DENIED, STATUS_SUCCESS
from impacket.ntlm import compute_nthash

logging.disable(logging.CRITICAL)


def inside_share(root, name):
    # Impacket 0.13.1 uses commonprefix, which also accepts sibling prefixes.
    # Resolve links and compare whole path components instead.
    try:
        root = os.path.realpath(root)
        return os.path.commonpath([root, os.path.realpath(os.path.join(root, name))]) == root
    except (ValueError, OSError):
        return False


smbserver.isInFileJail = inside_share

# Tell every client to sign, including WinPE and older Windows installations.
# Match the negotiate-validation reply so Windows can detect downgrades.
_validate_negotiate = smbserver.Ioctls.fsctlValidateNegotiateInfo
def validate_negotiate(connection_id, server, request):
    data, status = _validate_negotiate(connection_id, server, request)
    reply = smb2.VALIDATE_NEGOTIATE_INFO_RESPONSE(data)
    reply['SecurityMode'] = 3
    return reply.getData(), status
smbserver.Ioctls.fsctlValidateNegotiateInfo = staticmethod(validate_negotiate)

_negotiate = smbserver.SMB2Commands.smb2Negotiate
def negotiate(*args, **kwargs):
    replies, packets, status = _negotiate(*args, **kwargs)
    for response in packets or []:
        response['Data']['SecurityMode'] = 3
    return replies, packets, status
smbserver.SMB2Commands.smb2Negotiate = staticmethod(negotiate)


class PrivateSMBServer(smbserver.SMBSERVER):
    def log(self, *args, **kwargs):
        # Upstream logs NTLM responses. Never persist authentication material.
        pass

    def processRequest(self, connection_id, data):
        # Windows may offer SMB2 dialects inside the legacy negotiate envelope.
        # Allow only that upgrade handshake; never serve SMB1 sessions or files.
        if not data.startswith(b'\xfeSMB'):
            if data.startswith(b'\xffSMB') and data[4] == smb.SMB.SMB_COM_NEGOTIATE and (
                b'SMB 2.002\x00' in data or b'SMB 2.???\x00' in data
            ):
                return super().processRequest(connection_id, data)
            raise ConnectionError('SMB2 is required')
        state = self.getConnectionData(connection_id, False)
        if state.get('Authenticated'):
            key = state.get('SigningSessionKey', b'')
            offset = 0
            while offset < len(data):
                part = smb2.SMB2Packet(data=data[offset:])
                length = part['NextCommand'] or len(data) - offset
                if length < 64 or offset + length > len(data):
                    raise ConnectionError('Invalid SMB2 compound request')
                unsigned = bytearray(data[offset:offset+length])
                unsigned[48:64] = bytes(16)
                expected = hmac.new(key, unsigned, hashlib.sha256).digest()[:16]
                if not key or not part['Flags'] & smb2.SMB2_FLAGS_SIGNED or not hmac.compare_digest(expected, data[offset+48:offset+64]):
                    raise ConnectionError('A signed SMB2 request is required')
                offset += length
        return super().processRequest(connection_id, data)


def serve(config):
    parent = os.getppid()
    def watch_parent():
        while os.getppid() == parent:
            time.sleep(1)
        os._exit(0)
    threading.Thread(target=watch_parent, daemon=True).start()
    server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=0, smbserverclass=PrivateSMBServer)
    server.setSMB2Support(True)
    server.setSMBChallenge(secrets.token_hex(8))
    raw = server.getServer()
    cfg = raw.getServerConfig()
    cfg.set('global', 'anonymous_logon', 'no')
    raw.setServerConfig(cfg)
    raw.processConfigFile()
    server.addCredential('Lumen', 0, '', compute_nthash(config['password']).hex())
    for folder in config['folders']:
        path = os.path.realpath(folder['path'])
        if not os.path.isdir(path) or not os.access(path, os.R_OK):
            raise ValueError('A selected shared folder is unavailable')
        server.addShare(folder['name'], path, 'Lumen shared folder', readOnly='yes' if folder['readOnly'] else 'no')

    original_setup = raw.hookSmb2Command(smb2.SMB2_SESSION_SETUP, None)

    def authenticated_setup(connection_id, raw, packet):
        replies, packets, status = original_setup(connection_id, raw, packet)
        state = raw.getConnectionData(connection_id, False)
        # Upstream marks even failed or anonymous handshakes authenticated.
        allowed = status == STATUS_SUCCESS and state.get('user_name', '').lower() == 'lumen' and bool(state.get('SigningSessionKey'))
        state['Authenticated'] = allowed
        raw.setConnectionData(connection_id, state)
        if status == STATUS_SUCCESS and not allowed:
            status = STATUS_ACCESS_DENIED
        return replies, packets, status

    raw.hookSmb2Command(smb2.SMB2_SESSION_SETUP, authenticated_setup)
    print(json.dumps({'port': raw.server_address[1]}), flush=True)
    server.start()


if __name__ == '__main__':
    # Read secrets through stdin; do not place them in process arguments.
    serve(json.loads(sys.stdin.readline()))
