import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HELPER = Path(__file__).resolve().parents[1] / 'Integrations/Adapters/sandbox.py'
spec = importlib.util.spec_from_file_location('adapter_sandbox', HELPER)
sandbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sandbox)

class Handler(BaseHTTPRequestHandler):
    mode = 'normal'
    received = []
    def log_message(self, *_): pass
    def send(self, value):
        body = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.mode == 'redirect':
            self.send_response(302); self.send_header('Location', 'http://192.0.2.1/'); self.end_headers(); return
        self.send({'data': [{'id': 'test-lora'}]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.received.append((body, self.headers.get('Authorization')))
        self.send({'model': 'wrong' if self.mode == 'mismatch' else body['model'], 'choices': [{'message': {'content': 'fixture answer'}, 'finish_reason': 'stop'}]})

class SandboxTests(unittest.TestCase):
    def execute(self, executable='/bin/sh', arguments=None, **kwargs):
        request = {'action': 'execute', 'executable': executable, 'arguments': arguments or ['-c', 'cat'], 'input': 'fixture input', **kwargs}
        p = subprocess.run([sys.executable, '-I', str(HELPER)], input=json.dumps(request), text=True, capture_output=True, timeout=40)
        response = json.loads(p.stdout)
        self.assertTrue(response['ok'], response)
        return response['result']
    def test_stdio_exit(self):
        result = self.execute(arguments=['-c', 'cat; echo failure >&2; exit 7'])
        self.assertEqual(result['stdout'], 'fixture input'); self.assertEqual(result['exit_code'], 7)
        self.assertIn('failure', result['stderr'])
    def test_denies_external_read_write_and_network(self):
        with tempfile.TemporaryDirectory() as folder:
            secret = Path(folder) / 'secret'; secret.write_text('SECRET_SENTINEL')
            destination = Path(folder) / 'escape'
            result = self.execute(arguments=['-c', f'cat "{secret}"; echo bad > "{destination}"; /usr/bin/curl --connect-timeout 1 http://127.0.0.1:9; echo safe > inside; cat inside'])
            self.assertNotIn('SECRET_SENTINEL', result['stdout'])
            self.assertFalse(destination.exists()); self.assertIn('safe', result['stdout'])
            self.assertIn('Operation not permitted', result['stderr'])
    def test_network_denial_against_listening_server(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            result = self.execute(executable='/usr/bin/curl', arguments=['--connect-timeout', '1', f'http://127.0.0.1:{server.server_port}/v1/models'])
            self.assertNotEqual(result['exit_code'], 0)
            self.assertNotIn('test-lora', result['stdout'])
        finally:
            server.shutdown(); server.server_close(); thread.join()
    def test_cannot_signal_unrelated_process(self):
        target = subprocess.Popen(['/bin/sleep', '10'])
        try:
            result = self.execute(arguments=['-c', f'kill -TERM {target.pid}'])
            self.assertNotEqual(result['exit_code'], 0)
            self.assertIsNone(target.poll())
        finally:
            target.terminate(); target.wait()
    def test_environment_and_disposable_home(self):
        os.environ['PLANISPHERE_DEMO_SECRET'] = 'do-not-inherit'
        result = self.execute(arguments=['-c', 'env; pwd'])
        self.assertNotIn('do-not-inherit', result['stdout'])
        home = next(x[5:] for x in result['stdout'].splitlines() if x.startswith('HOME='))
        self.assertFalse(Path(home).exists())
    def test_timeout_and_output_limit(self):
        self.assertEqual(self.execute(arguments=['-c', 'sleep 10'], timeout=1)['outcome'], 'timed_out')
        result = self.execute(executable='/usr/bin/yes', arguments=['x'])
        self.assertEqual(result['outcome'], 'output_limit')
        self.assertLessEqual(len(result['stdout'].encode()) + len(result['stderr'].encode()), sandbox.LIMIT)
    def test_fixture_does_not_claim_execution(self):
        result = sandbox.fixture({'host': 'codex', 'input': '{"session_id":"test","cwd":"/sandbox"}'})
        self.assertIn('No hook ran', result['coverage'])
        with self.assertRaises(ValueError): sandbox.fixture({'host': 'claude', 'input': '{}'})
    def test_endpoint_restrictions(self):
        for address in ['https://example.com', 'http://localhost:1234', 'http://127.0.0.1@evil.com', 'http://127.0.0.1/x', 'file:///etc/passwd', 'http://127.0.0.1?x=y']:
            with self.assertRaises(ValueError, msg=address): sandbox.endpoint(address)
        self.assertEqual(sandbox.endpoint('http://[::1]:1234/v1'), 'http://[::1]:1234/v1')
    def test_model_request_identity_usage_and_redirect(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            request = {'action': 'model', 'endpoint': f'http://127.0.0.1:{server.server_port}', 'token': 'fixture-token', 'model': 'test-lora', 'input': 'fixture prompt', 'max_tokens': 16}
            Handler.mode = 'normal'
            result = sandbox.model_test(request)
            self.assertIsNone(result['usage']); self.assertEqual(result['output'], 'fixture answer')
            body, auth = Handler.received[-1]
            self.assertEqual(body['model'], 'test-lora'); self.assertEqual(auth, 'Bearer fixture-token')
            self.assertEqual(body['messages'], [{'role': 'user', 'content': 'fixture prompt'}])
            Handler.mode = 'mismatch'
            with self.assertRaisesRegex(ValueError, 'selected model'): sandbox.model_test(request)
            Handler.mode = 'redirect'
            with self.assertRaisesRegex(ValueError, 'Redirect refused'): sandbox.model_test(request)
        finally:
            server.shutdown(); server.server_close(); thread.join()

if __name__ == '__main__': unittest.main()
