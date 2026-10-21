#!/usr/bin/env python3
"""Prepare a pinned, project-local runtime; never install system services."""
from pathlib import Path
import subprocess
import sys
import shutil
import importlib.metadata
import re
if sys.version_info[:2] != (3, 14):
    raise SystemExit('Windows sharing must be prepared with Python 3.14 (brew install python@3.14).')
root=Path(__file__).resolve().parents[1]
target=root/'.runtime/WindowsSharing'
lock=root/'scripts/sharing/requirements-macos-arm64-py314.txt'
normalize=lambda name: re.sub(r'[-_.]+','-',name).lower()
expected={normalize(line.split('==')[0]):line.split('==')[1].split()[0] for line in lock.read_text().splitlines() if line and not line.startswith('#')}
installed={normalize(d.metadata['Name']):d.version for d in importlib.metadata.distributions(path=[str(target)])}
if installed != expected:
    staging=target.with_name('WindowsSharing.staging')
    if staging.exists(): shutil.rmtree(staging)
    cached=root/'build/sharing-packages'
    cache_args=['--no-index','--find-links',str(cached)] if len(list(cached.glob('*.whl'))) == len(expected) else []
    subprocess.run([sys.executable,'-m','pip','install','--require-hashes','--only-binary=:all:',*cache_args,'--target',str(staging),'-r',str(lock)],check=True)
    if target.exists(): shutil.rmtree(target)
    staging.rename(target)
for cache in target.rglob('__pycache__'):
    shutil.rmtree(cache)
shutil.copy2(root/'scripts/sharing/server.py',target/'server.py')
