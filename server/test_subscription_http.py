#!/usr/bin/env python3
"""Exercise the actual HTTPS listener in a marked disposable Linux environment."""
import hashlib, http.client, json, os, pathlib, socket, ssl, subprocess, sys
if os.geteuid() != 0 or not pathlib.Path('/etc/hihy-test-environment').exists():
    raise SystemExit('Disposable root Linux environment required')
state = json.loads(subprocess.check_output(['/etc/hihy/bin/yq','-o=json','.','/etc/hihy-sub/state.yaml'],text=True))
domain, token = state['domain'], state['token']
context = ssl.create_default_context(cafile=os.environ['CURL_CA_BUNDLE'])
class Connection(http.client.HTTPSConnection):
    def connect(self):
        self.sock = self._context.wrap_socket(socket.create_connection(('127.0.0.1',443), self.timeout), server_hostname=self.host)
for host, tls in [(domain,ssl.create_default_context()),('wrong.example.test',context)]:
    c=Connection(host,context=tls,timeout=10)
    try:
        try: c.connect()
        except ssl.SSLError: pass
        else: raise AssertionError('Untrusted certificate or wrong SNI was accepted')
    finally: c.close()
print('PASS: HTTPS rejects an untrusted CA and a mismatched SNI')

def request(path, ua='', method='GET', extra=None):
    c=Connection(domain,context=context,timeout=10)
    try:
        c.request(method,path,headers={'User-Agent':ua,**(extra or {})})
        response=c.getresponse()
        return response.status,dict((k.lower(),v) for k,v in response.getheaders()),response.read()
    finally: c.close()
base='/s/'+token
files={'hysteria':'hysteria.yaml','mihomo':'mihomo.yaml','singbox':'singbox.json'}
payloads={k:(pathlib.Path('/var/lib/hihy-sub/content/current')/v).read_bytes() for k,v in files.items()}
for ua,kind in [('v2rayN/7.25.6','hysteria'),('clash-verge/v2.5.10','mihomo'),('mihomo/1.19.34','mihomo'),('SFA (sing-box 1.14.4; language en_US)','singbox'),('SFI (sing-box 1.14.4; language zh_CN)','singbox'),('SFM (sing-box 1.14.4; language en_US)','singbox')]:
    status,headers,body=request(base,ua)
    assert status==200 and body==payloads[kind],(ua,status)
    assert 'no-store' in headers['cache-control'] and 'user-agent' in headers['vary'].lower()
    assert 'etag' not in headers and 'last-modified' not in headers
print('PASS: one HTTPS URL selects complete configurations for v2rayN, Clash Verge, mihomo, SFA, SFI and SFM')
for kind in files:
    status,_,body=request(base+'?format='+kind,'unknown-client')
    assert status==200 and body==payloads[kind],kind
for path,ua,expected in [(base,'Mozilla/5.0',400),(base+'?format=unknown','v2rayN/7.25.6',400),('/s/'+'0'*64,'v2rayN/7.25.6',404),('/hysteria.yaml','v2rayN/7.25.6',404),('/Caddyfile','v2rayN/7.25.6',404),(base+'/../../Caddyfile','v2rayN/7.25.6',404)]:
    status,_,body=request(path,ua)
    assert status==expected,(path.replace(token,'[token]'),status)
    assert token.encode() not in body and b'auth:' not in body
assert request(base,'v2rayN/7.25.6','POST')[0]==405
status,_,body=request(base,'v2rayN/7.25.6','HEAD')
assert status==200 and body==b''
print('PASS: explicit formats, unknown clients, wrong token, traversal, hidden files and method restrictions')
status,_,body=request(base,'v2rayN/7.25.6',extra={'If-Modified-Since':'Wed, 31 Dec 2099 23:59:59 GMT','If-None-Match':'*','Range':'bytes=0-8'})
assert status==200 and body==payloads['hysteria']
mobile=json.loads(payloads['singbox'])
assert mobile['inbounds'][0]['type']=='tun' and mobile['route']['rules'][0]['action']=='hijack-dns'
assert all(x['type'] not in ('mixed','http','socks') for x in mobile['inbounds'])
assert 'clash_api' not in mobile.get('experimental',{})
server=json.loads(subprocess.check_output(['/etc/hihy/bin/yq','-o=json','.','/etc/hihy/conf/config.yaml'],text=True))
for body in payloads.values():
    assert server['trafficStats']['secret'].encode() not in body
    assert b'PRIVATE KEY-----' not in body
print('PASS: cache isolation, complete mobile TUN/DNS profile, and private server data excluded')
if len(sys.argv)>1:
    old=pathlib.Path(sys.argv[1]).read_text().strip()
    assert request('/s/'+old,'v2rayN/7.25.6')[0]==404
    print('PASS: old token is revoked while the same three formats remain available')
