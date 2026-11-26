#!/usr/bin/env python3
"""Run real transport tests only in an explicitly marked disposable Linux VM."""
import copy, hashlib, http.client, http.server, json, os, pathlib, shlex, socket, ssl, subprocess, sys, tempfile, threading, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
if os.geteuid() != 0 or not pathlib.Path('/etc/hihy-test-environment').exists():
    raise SystemExit('Requires root in a disposable VM with /etc/hihy-test-environment')
TOOLS = pathlib.Path(os.environ.get('HIHY_TEST_CORES', '/home/review/cores'))
YQ = '/etc/hihy/bin/yq'
CORE = '/etc/hihy/bin/appS'
NS = 'hihy-review-' + str(os.getpid())
VETH = 'hy' + str(os.getpid())
CLIENT_IP = '10.203.0.2'
SERVER_IP = '10.203.0.1'
PASSWORD = 'test:@/?#%&" with spaces'
RESULTS = []
SUBSCRIPTION = os.environ.get('HIHY_TEST_SUBSCRIPTION') == '1'
TUN_TARGET = '203.0.113.1'

def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

def shell(code, check=True):
    return subprocess.run(['bash', '-c', 'source ' + shlex.quote(str(ROOT/'server/hy2.sh')) + '; ' + code],
        check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def configure(extra=''):
    code = 'setConfigDefaults; auth_secret=' + shlex.quote(PASSWORD) + '; ip=' + SERVER_IP
    code += '; port=34567; domain=server.test; remarks=' + shlex.quote('test/../quoted" name')
    code += '; ' + extra + '; writeHysteriaConfig && generate_client_config'
    result = shell(code)
    return result

def yaml_read(file):
    return json.loads(run([YQ, '-o=json', '.', str(file)]).stdout)

class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'HIHY-E2E')
    def log_message(self, *args):
        pass

def client_request(kind, config, directory, expected=True, host=None):
    directory.mkdir(parents=True, exist_ok=True)
    port = {'native':20808, 'mihomo':20809, 'sing-box':20810}[kind]
    config = copy.deepcopy(config)
    if kind == 'native':
        config['socks5'] = {'listen':'127.0.0.1:' + str(port)}
        cmd = [CORE, '--disable-update-check', '-c', str(directory/'config.json'), 'client']
    elif kind == 'mihomo':
        config['mixed-port'] = port
        config['dns']['enable'] = False
        config['rule-providers'] = {}
        config['rules'] = ['MATCH,PROXY']
        cmd = [str(TOOLS/'mihomo'), '-d', str(directory), '-f', str(directory/'config.json')]
    else:
        config['inbounds'] = [{'type':'mixed', 'listen':'127.0.0.1', 'listen_port':port}]
        config['route']['rules'] = []
        config['route']['rule_set'] = []
        config['dns']['rules'] = []
        config.pop('experimental', None)
        cmd = [str(TOOLS/'sing-box'), 'run', '-D', str(directory), '-c', str(directory/'config.json')]
    file = directory/'config.json'
    file.write_text(json.dumps(config, ensure_ascii=False)); file.chmod(0o600)
    if kind == 'mihomo':
        run([str(TOOLS/'mihomo'), '-t', '-d', str(directory), '-f', str(file)])
    elif kind == 'sing-box':
        run([str(TOOLS/'sing-box'), 'check', '-c', str(file)])
    with (directory/'client.log').open('w') as log:
        process = subprocess.Popen(['ip','netns','exec',NS] + cmd, stdout=log, stderr=log)
        try:
            ok = False
            for attempt in range(12 if expected else 2):
                time.sleep(1)
                result = subprocess.run(['ip','netns','exec',NS,'curl','--silent','--show-error','--max-time','5',
                    '--socks5-hostname','127.0.0.1:'+str(port),'http://'+SERVER_IP+':19080/test'] +
                    (['-H', 'Host: ' + host] if host else []),
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode == 0 and result.stdout == 'HIHY-E2E':
                    ok = True; break
                if process.poll() is not None:
                    break
            if ok != expected:
                raise AssertionError(kind + ' transport expectation failed: ' + (directory/'client.log').read_text()[-3500:])
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=8)
                except subprocess.TimeoutExpired: process.kill(); process.wait()

def get_exports():
    if SUBSCRIPTION:
        state = yaml_read('/etc/hihy-sub/state.yaml')
        context = ssl.create_default_context(cafile=os.environ['CURL_CA_BUNDLE'])
        class FeedConnection(http.client.HTTPSConnection):
            def connect(self):
                self.sock = self._context.wrap_socket(socket.create_connection(('127.0.0.1',443),10),server_hostname=self.host)
        configs = {}
        for kind, ua, file in [('native','v2rayN/7.25.6','hysteria.yaml'),('mihomo','clash-verge/v2.5.10','mihomo.yaml'),('sing-box','SFA (sing-box 1.14.4)','singbox.json')]:
            c=FeedConnection(state['domain'],context=context,timeout=10)
            try:
                c.request('GET','/s/'+state['token'],headers={'User-Agent':ua})
                response=c.getresponse(); body=response.read()
                assert response.status==200
                assert body==(pathlib.Path('/var/lib/hihy-sub/content/current')/file).read_bytes()
                configs[kind]=json.loads(run([YQ,'-o=json','.'],input=body.decode()).stdout)
            finally: c.close()
        return configs
    directory = pathlib.Path('/etc/hihy/result')
    return {kind:yaml_read(sorted(directory.glob('*-'+suffix))[-1]) for kind,suffix in
        [('native','v2rayN.yaml'),('mihomo','mihomo.yaml'),('sing-box','singbox.json')]}

def tun_request(config, directory):
    """Run the unmodified complete app profile through a real Linux TUN."""
    directory.mkdir(parents=True,exist_ok=True)
    file=directory/'config.json'; file.write_text(json.dumps(config)); file.chmod(0o600)
    args=['ip','netns','exec',NS,'curl','--noproxy','*','--silent','--show-error','--max-time','3','http://'+TUN_TARGET+':19081/test']
    assert subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0
    with (directory/'tun.log').open('w') as log:
        p=subprocess.Popen(['ip','netns','exec',NS,str(TOOLS/'sing-box'),'run','-D',str(directory),'-c',str(file)],stdout=log,stderr=log)
        try:
            ok=False
            for _ in range(45):
                time.sleep(1)
                r=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                if r.returncode==0 and r.stdout=='HIHY-E2E': ok=True; break
                if p.poll() is not None: break
            if not ok: raise AssertionError('Full app TUN transport failed: '+(directory/'tun.log').read_text()[-3000:])
        finally:
            p.terminate()
            try: p.wait(timeout=8)
            except subprocess.TimeoutExpired: p.kill(); p.wait()
    assert subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0

try:
    run(['ip','netns','add',NS])
    run(['ip','link','add',VETH,'type','veth','peer','name','eth-review','netns',NS])
    run(['ip','addr','add',SERVER_IP+'/30','dev',VETH]); run(['ip','link','set',VETH,'up'])
    run(['ip','netns','exec',NS,'ip','addr','add',CLIENT_IP+'/30','dev','eth-review'])
    run(['ip','netns','exec',NS,'ip','link','set','eth-review','up'])
    run(['ip','netns','exec',NS,'ip','link','set','lo','up'])
    if SUBSCRIPTION:
        run(['ip','netns','exec',NS,'ip','route','add','default','via',SERVER_IP])
        run(['ip','netns','exec',NS,'iptables','-A','OUTPUT','-d',TUN_TARGET+'/32','-o','eth-review','-j','REJECT'])
        run(['ip','addr','add',TUN_TARGET+'/32','dev','lo'])
        tun_origin=http.server.ThreadingHTTPServer((TUN_TARGET,19081),Origin)
        threading.Thread(target=tun_origin.serve_forever,daemon=True).start()
    origin = http.server.ThreadingHTTPServer((SERVER_IP,19080),Origin)
    threading.Thread(target=origin.serve_forever,daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='hihy-e2e-') as tmp:
        temp = pathlib.Path(tmp)
        for case, options in [('baseline',':'),('gecko-ech','obfs_status=true; obfs_type=gecko; obfs_pass='+shlex.quote(PASSWORD)+'; ech_status=true; ech_public_name=public.test; congestion_bbr_profile=aggressive'),('hopping','portHoppingStatus=true; portHoppingStart=47000; portHoppingEnd=47003; portHoppingIntervalMode=fixed; portHoppingHopInterval=5s')]:
            configure(options)
            configs = get_exports()
            for kind in ['mihomo', 'sing-box']:
                full = temp / (case + '-' + kind + '-full.json')
                full.write_text(json.dumps(configs[kind], ensure_ascii=False)); full.chmod(0o600)
                if kind == 'mihomo':
                    run([str(TOOLS/kind), '-t', '-d', str(temp), '-f', str(full)])
                else:
                    run([str(TOOLS/kind), 'check', '-c', str(full)])
            for kind, config in configs.items():
                client_request(kind,config,temp/case/kind)
                RESULTS.append(case + '/' + kind + ': connected')
                print('PASS',RESULTS[-1],flush=True)
            if SUBSCRIPTION:
                tun_request(configs['sing-box'],temp/case/'app-tun')
                RESULTS.append(case+'/sing-box: unmodified HTTPS app profile connected through real TUN')
                print('PASS',RESULTS[-1],flush=True)
            if case == 'baseline':
                for kind, config in configs.items():
                    bad = copy.deepcopy(config)
                    if kind == 'native': bad['auth']='wrong-password'
                    elif kind == 'mihomo': bad['proxies'][0]['password']='wrong-password'
                    else: bad['outbounds'][0]['password']='wrong-password'
                    client_request(kind,bad,temp/'wrong-auth'/kind,False)
                    if kind == 'native': bad=config|{'tls':dict(config['tls'],pinSHA256='00'*32)}
                    elif kind == 'mihomo':
                        bad=copy.deepcopy(config); bad['proxies'][0]['fingerprint']='00'*32
                    else:
                        bad=copy.deepcopy(config); bad['outbounds'][0]['tls'].pop('certificate',None)
                    client_request(kind,bad,temp/'wrong-trust'/kind,False)
                    RESULTS.append(kind+': wrong auth and certificate rejected'); print('PASS',RESULTS[-1],flush=True)
        original=hashlib.sha256(pathlib.Path('/etc/hihy/conf/config.yaml').read_bytes()).hexdigest()
        invalid=temp/'invalid.crt'; invalid.write_text('invalid certificate')
        old_key=yaml_read('/etc/hihy/conf/config.yaml')['tls']['key']
        result=shell('setConfigDefaults; port=34567; ip='+SERVER_IP+'; auth_secret=test; domain=server.test; useLocalCert=true; local_cert='+shlex.quote(str(invalid))+'; local_key='+shlex.quote(old_key)+'; writeHysteriaConfig',False)
        assert result.returncode != 0
        assert hashlib.sha256(pathlib.Path('/etc/hihy/conf/config.yaml').read_bytes()).hexdigest()==original
        assert shell('getServiceRunState').stdout.strip()=='running'
        RESULTS.append('failed reconfiguration restored running service'); print('PASS',RESULTS[-1],flush=True)
        configure(':')
        native = get_exports()['native']
        candidate = temp/'sniff.yaml'
        acl = temp/'sniff.acl'
        shell('cp /etc/hihy/conf/config.yaml ' + shlex.quote(str(candidate)) +
              '; addOrUpdateYaml ' + shlex.quote(str(candidate)) + ' sniff.tcpPorts 19080 string' +
              '; cp /etc/hihy/acl/acl.txt ' + shlex.quote(str(acl)) +
              '; printf \'reject(suffix:sniff-blocked.test)\\n\' >>' + shlex.quote(str(acl)) +
              '; commitServerEdit ' + shlex.quote(str(candidate)) + ' ' + shlex.quote(str(acl)))
        client_request('native', native, temp/'sniff-allowed')
        client_request('native', native, temp/'sniff-blocked', False, host='sniff-blocked.test')
        RESULTS.append('sniff.enable enforces HTTP Host ACL for an IP destination'); print('PASS',RESULTS[-1],flush=True)
        configure('masquerade_status=true; masquerade_type=file; masquerade_file=/etc/hihy/file; masquerade_tcp=true')
        site = run(['curl', '--silent', '--show-error', '--fail', '--max-time', '10', '--noproxy', '*',
                    '--cacert', '/etc/hihy/result/server.test.ca.crt', '--resolve',
                    'server.test:34567:' + SERVER_IP, 'https://server.test:34567/']).stdout
        assert 'mikutap' in site.lower()
        RESULTS.append('verified default site serves over certificate-verified HTTPS'); print('PASS',RESULTS[-1],flush=True)
        configure(':')
    print(json.dumps({'passed':RESULTS},indent=2),flush=True)
finally:
    if 'origin' in globals(): origin.shutdown(); origin.server_close()
    if 'tun_origin' in globals():
        tun_origin.shutdown(); tun_origin.server_close()
        subprocess.run(['ip','addr','del',TUN_TARGET+'/32','dev','lo'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['ip','netns','del',NS],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['ip','link','del',VETH],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
