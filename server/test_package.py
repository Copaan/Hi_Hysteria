#!/usr/bin/env python3
"""Verify the standalone installer and the minimal optional distribution bundle."""
import hashlib, pathlib, re, tarfile
root=pathlib.Path(__file__).resolve().parents[1]
version=re.search(r'^hihyV="([^"]+)"$',(root/'server/src/00-header.sh').read_text(encoding='utf-8'),re.M)[1]
name='hihy-'+version
archive=root/'dist'/f'{name}.tar.gz'
standalone=root/'dist'/f'install-{version}.sh'
for file in (archive,standalone):
    digest,filename=file.with_name(file.name+'.sha256').read_text().strip().split(maxsplit=1)
    assert filename==file.name
    assert hashlib.sha256(file.read_bytes()).hexdigest()==digest
assert standalone.read_bytes()==(root/'server/install.sh').read_bytes()
with tarfile.open(archive) as tar:
    members=tar.getmembers()
    allowed={'install.sh','hy2.sh','SHA256SUMS','LICENSE','INSTALL.md','SUBSCRIPTIONS.md'}
    assert {m.name.removeprefix(name+'/') for m in members if m.isfile()}==allowed
    assert all(not(m.issym() or m.islnk()) and not(m.mode & 0o077) for m in members)
    assert all(m.name==name or (m.name.startswith(name+'/') and '..' not in pathlib.PurePosixPath(m.name).parts) for m in members)
    manifest=tar.extractfile(name+'/SHA256SUMS').read().decode()
    assert len(manifest.splitlines())==2
    for line in manifest.splitlines():
        digest,filename=line.split(maxsplit=1)
        assert filename in ('install.sh','hy2.sh')
        data=tar.extractfile(name+'/'+filename).read()
        assert data==(root/'server'/filename).read_bytes()
        assert hashlib.sha256(data).hexdigest()==digest
        assert b'\r' not in data
    assert tar.extractfile(name+'/install.sh').read()==standalone.read_bytes()
print('PASS: standalone checksum, exact runtime, minimal bundle, safe members, private modes and LF')
