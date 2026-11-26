#!/usr/bin/env python3
"""Check built-in Chinese messages and referenced keys without language packs."""
import pathlib, re, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
module=root/'server/src/10-messages.sh'
source=module.read_text(encoding='utf-8')
keys=re.findall(r"^        ([a-zA-Z0-9_]+)\) printf '%s'",source,re.M)
assert len(keys)>500 and len(keys)==len(set(keys))
used=set()
for file in (root/'server/src').glob('*.sh'):
    text=file.read_text(encoding='utf-8')
    used.update(re.findall(r'\b(?:msg|subscriptionError)\s+([a-z][a-z0-9_]*)',text))
    assert not re.search(r'HIHY_I18N|HIHY_LANG|loadPersistedLanguage|i18nLookup',text),file
assert not used-set(keys),sorted(used-set(keys))
r=subprocess.run(['bash','-c','source "$1"; shift; for key; do messageTemplate "$key" || exit 1; printf "\\0"; done','--',str(module),*keys],check=True,stdout=subprocess.PIPE)
values=r.stdout.split(b'\0')[:-1]
assert len(values)==len(keys) and all(values)
value='中文 "引号" \\ 100% %n\n$(printf should-not-run)'
r=subprocess.run(['bash','-c','source "$1"; msg service_running "$2"','--',str(module),value],check=True,stdout=subprocess.PIPE)
assert r.stdout.decode()==value+'正在运行'
r=subprocess.run(['bash','-c','source "$1"; msg traffic_stats_row "$2" "$3" "$4"','--',str(module),'user%name','12 KB','30 KB'],check=True,stdout=subprocess.PIPE)
assert r.stdout.decode()=='用户: %-20s 上传: %8s  下载: %8s' % ('user%name','12 KB','30 KB')
r=subprocess.run(['bash','-c','source "$1"; msg missing_message','--',str(module)],stdout=subprocess.PIPE)
assert r.returncode!=0
print('PASS: all Chinese keys, formatted arguments, Unicode, quotes, newlines and literal shell-like input')
