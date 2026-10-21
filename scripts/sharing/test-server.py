import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
from impacket.smbconnection import SMBConnection, SessionError

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='lumen-sharing-') as temp:
    temp=Path(temp); rw=temp/'folder'; ro=temp/'read-only'; sibling=temp/'folder-secret'
    for p in (rw,ro,sibling): p.mkdir()
    (rw/'hello.txt').write_bytes(b'hello');(ro/'hello.txt').write_bytes(b'read only');(sibling/'secret.txt').write_bytes(b'secret')
    (rw/'escape').symlink_to(sibling, target_is_directory=True)
    password=secrets.token_hex(32)
    proc=subprocess.Popen([sys.executable,str(root/'scripts/sharing/server.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        proc.stdin.write(json.dumps({'password':password,'folders':[{'name':'Desktop','path':str(rw),'readOnly':False},{'name':'ReadOnly','path':str(ro),'readOnly':True}]})+'\n');proc.stdin.flush()
        ready=proc.stdout.readline(); assert ready,proc.stderr.read()
        port=json.loads(ready)['port']
        def connect(user,pw):
            c=SMBConnection('Lumen','127.0.0.1',sess_port=port)
            c.login(user,pw)
            return c
        for user,pw in [('Lumen','wrong'),('',''),('someone',password)]:
            rejected=SMBConnection('Lumen','127.0.0.1',sess_port=port)
            try: rejected.login(user,pw)
            except SessionError: pass
            else: rejected.close();raise AssertionError('Invalid credentials accepted')
            try: rejected.connectTree('Desktop')
            except Exception: pass
            else: raise AssertionError('Failed login still allowed folder access')
            rejected.close()
        c=connect('Lumen',password)
        assert {s['shi1_netname'][:-1] for s in c.listShares()} >= {'DESKTOP','READONLY'}
        buf=io.BytesIO();c.getFile('Desktop','hello.txt',buf.write);assert buf.getvalue()==b'hello'
        c.putFile('Desktop','written.txt',io.BytesIO(b'from guest').read);assert (rw/'written.txt').read_bytes()==b'from guest'
        for share,path in [('Desktop','escape/secret.txt'),('Desktop','../folder-secret/secret.txt')]:
            try: c.getFile(share,path,io.BytesIO().write)
            except SessionError: pass
            else: raise AssertionError('Escaped selected folder')
        try:c.putFile('ReadOnly','bad.txt',io.BytesIO(b'bad').read)
        except SessionError: pass
        else:raise AssertionError('Read-only share accepted writes')
        assert not (ro/'bad.txt').exists()
        for operation in [lambda: c.deleteFile('ReadOnly','hello.txt'), lambda: c.createDirectory('ReadOnly','bad-directory'), lambda: c.rename('ReadOnly','hello.txt','renamed.txt')]:
            try: operation()
            except SessionError: pass
            else: raise AssertionError('Read-only share accepted a mutation')
        assert (ro/'hello.txt').read_bytes()==b'read only'
        assert not (ro/'bad-directory').exists()
        c.deleteFile('Desktop','written.txt');assert not (rw/'written.txt').exists()
        c.close()
        unsigned=connect('Lumen',password)
        unsigned.getSMBServer()._Session['SigningActivated']=False
        try: unsigned.connectTree('Desktop')
        except Exception: pass
        else: raise AssertionError('Unsigned authenticated request was accepted')
        unsigned.close()
        print('PASS: signed SMB2, multiple folders, read/write/delete, read-only enforcement, failed/anonymous login isolation, unsigned request rejection, traversal and escaping symlink rejection; loopback only')
    finally:
        proc.terminate();proc.wait(timeout=5)
