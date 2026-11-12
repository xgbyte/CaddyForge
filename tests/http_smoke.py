#!/usr/bin/env python3
"""Execute trusted local artifacts against loopback only; no ACME or DNS calls."""
import json, pathlib, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
root = pathlib.Path(__file__).resolve().parents[1]
artifact = pathlib.Path(sys.argv[1]).resolve()
binary = str(artifact / 'caddy')
modules = subprocess.check_output([binary, 'list-modules'], text=True).splitlines()
def request(port, path='/'):
    try:
        with opener.open(f'http://127.0.0.1:{port}{path}', timeout=2) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code

def test(example, assertions):
    config = json.loads(subprocess.check_output([binary, 'adapt', '--adapter', 'caddyfile', '--config', str(root / 'examples' / example)]))
    config['admin'] = {'disabled': True}
    def tune_limiter(value):
        if isinstance(value, dict):
            if value.get('handler') == 'rate_limit':
                for zone in value['rate_limits'].values():
                    zone.update(window=60_000_000_000, max_events=2)
            for child in value.values():
                tune_limiter(child)
        elif isinstance(value, list):
            for child in value:
                tune_limiter(child)
    # Keep the behavior assertion independent of CI request throughput.
    tune_limiter(config)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    for server in config['apps']['http']['servers'].values():
        server['listen'] = [f'127.0.0.1:{port}']
    with tempfile.TemporaryDirectory() as temp:
        cfg = pathlib.Path(temp) / 'test.json'
        cfg.write_text(json.dumps(config))
        with open(pathlib.Path(temp) / 'server.log', 'w+') as log:
            proc = subprocess.Popen([binary, 'run', '--config', str(cfg)], stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if proc.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(log.read())
                    try:
                        request(port)
                        break
                    except (OSError, urllib.error.URLError):
                        time.sleep(.1)
                else:
                    raise RuntimeError('Local server did not become ready')
                assertions(port)
                print('ok - ' + example)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

def basic(port):
    assert request(port, '/healthz') == 200

def waf(port):
    assert request(port) == 200
    assert request(port, '/?x=%3Cscript%3Ealert(1)%3C%2Fscript%3E') == 403

def limiter(port):
    statuses = [request(port) for _ in range(40)]
    assert 429 in statuses, statuses

test('Caddyfile', basic)
test('Caddyfile.coraza', waf)
if 'http.handlers.rate_limit' in modules:
    test('Caddyfile.ratelimit', limiter)
