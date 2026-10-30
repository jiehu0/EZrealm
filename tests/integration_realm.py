"""Real Realm TCP forwarding tests; set REALM_BINARY to enable.

The service bridge starts/stops a temporary Realm subprocess in place of
systemd. All forwarding traffic stays on loopback. No root access is used.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
import json
from pathlib import Path
import shlex
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("REALM_BINARY")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class IntegrationCases:
    def setUp(self):
        if not BINARY:
            self.skipTest("set REALM_BINARY to run real forwarding tests")
        self.temp = tempfile.TemporaryDirectory(prefix="ezrealm integration ")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.systemd = os.environ.get("REALM_TEST_SYSTEMD") == "1"
        self.unit = None
        self.process = None
        self.log = (self.folder / "realm.log").open("ab")
        self.addCleanup(self.log.close)
        self.addCleanup(self.stop_realm)
        self.echo_a = self.echo_server(b"A:")
        self.echo_b = self.echo_server(b"B:")
        self.listen_port = free_port()
        self.other_port = free_port()
        self.config = self.folder / "config.toml"
        self.original = (
            '[network]\nno_tcp = false\nuse_udp = false\n\n'
            '[[endpoints]]\n# 备注: first\n'
            f'listen = "127.0.0.1:{self.listen_port}"\n'
            f'remote = "127.0.0.1:{self.echo_a.server_address[1]}"\n\n'
            '[[endpoints]]\n# 备注: untouched\n'
            f'listen = "127.0.0.1:{self.other_port}"\n'
            f'remote = "127.0.0.1:{self.echo_a.server_address[1]}"\n'
        )
        self.config.write_text(self.original)
        if self.systemd:
            self.unit = f"ezrealm-test-{os.getpid()}.service"
            self.unit_path = f"/run/systemd/system/{self.unit}"
            contents = (
                '[Unit]\nDescription=Temporary EZrealm integration test\n'
                '[Service]\nType=simple\n'
                f'ExecStart="{BINARY}" -c "{self.config}"\n'
                'Restart=no\n'
            )
            self.addCleanup(self.remove_unit)
            subprocess.run(["sudo", "tee", self.unit_path], input=contents,
                           text=True, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["sudo", "systemctl", "daemon-reload"], check=True)
            self.start_realm()
            self.assert_forward(self.listen_port, b"A:payload")
            return
        owner = self

        class ServiceHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                action = self.rfile.read(int(self.headers["Content-Length"])).decode()
                if action == "restart":
                    owner.start_realm()
                    code = 0
                elif action == "stop":
                    owner.stop_realm()
                    code = 0
                elif action == "show":
                    code = 0
                else:
                    code = int(owner.process is None or owner.process.poll() is not None)
                output = str(owner.process.pid) + "\n" if action == "show" and owner.process else ""
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({"code": code, "output": output}).encode())

            def log_message(self, *args):
                pass

        self.service = HTTPServer(("127.0.0.1", 0), ServiceHandler)
        thread = threading.Thread(target=self.service.serve_forever, kwargs={"poll_interval": .05}, daemon=True)
        thread.start()
        self.addCleanup(self.service.server_close)
        self.addCleanup(self.service.shutdown)
        self.bridge = self.folder / "service_bridge.py"
        self.bridge.write_text(
            'import sys, urllib.request, json\n'
            'request = urllib.request.Request(sys.argv[1], data=sys.argv[2].encode())\n'
            'with urllib.request.urlopen(request, timeout=5) as response:\n'
            '    result = json.load(response)\n'
            'sys.stdout.write(result["output"])\n'
            'sys.exit(result["code"])\n'
        )
        self.start_realm()
        self.assert_forward(self.listen_port, b"A:payload")

    def echo_server(self, prefix, ipv6=False):
        class EchoHandler(socketserver.BaseRequestHandler):
            def handle(self):
                data = self.request.recv(1024)
                if data:
                    self.request.sendall(prefix + data)

        class EchoServer(socketserver.ThreadingTCPServer):
            address_family = socket.AF_INET6 if ipv6 else socket.AF_INET
            daemon_threads = True

        server = EchoServer(("::1" if ipv6 else "127.0.0.1", 0), EchoHandler)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .05}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def stop_realm(self):
        if self.systemd:
            if self.unit:
                subprocess.run(["sudo", "systemctl", "stop", self.unit], check=True)
            return
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
            self.process.wait(timeout=5)
            self.process = None

    def start_realm(self):
        if self.systemd:
            subprocess.run(["sudo", "systemctl", "restart", self.unit], check=True)
            return
        self.stop_realm()
        self.process = subprocess.Popen([BINARY, "-c", str(self.config)], stdout=self.log, stderr=self.log)

    def remove_unit(self):
        self.stop_realm()
        subprocess.run(["sudo", "rm", "-f", self.unit_path], check=True)
        subprocess.run(["sudo", "systemctl", "daemon-reload"], check=True)
        self.unit = None

    def assert_forward(self, port, expected, host="127.0.0.1"):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                with socket.create_connection((host, port), timeout=.3) as sock:
                    sock.sendall(b"payload")
                    response = b""
                    while len(response) < len(expected):
                        chunk = sock.recv(1024)
                        if not chunk:
                            break
                        response += chunk
                    if response == expected:
                        return
            except OSError:
                pass
            time.sleep(.05)
        self.fail(f"forwarding {host}:{port} did not return {expected!r}\n{(self.folder / 'realm.log').read_text()}")

    def edit(self, fields):
        body = f'source {shlex.quote(str(ROOT / self.script))}\n'
        body += f'CONFIG_FILE={shlex.quote(str(self.config))}\n'
        body += f'LOG_FILE={shlex.quote(str(self.folder / "manager.log"))}\n'
        if self.systemd:
            body += 'lsof() { sudo lsof "$@"; }\n'
            body += 'systemctl() { local arg args=(); for arg in "$@"; do '
            body += '[[ "$arg" != realm.service ]] || arg=' + shlex.quote(self.unit) + '; '
            body += 'args+=("$arg"); done; sudo systemctl "${args[@]}"; }\nedit_rule\n'
        else:
            args = [sys.executable, str(self.bridge), f'http://127.0.0.1:{self.service.server_port}']
            body += 'systemctl() { ' + shlex.join(args) + ' "$1"; }\nedit_rule\n'
        return subprocess.run(["bash", "-c", body], input="\n".join(["1", *fields, "y"]) + "\n",
                              text=True, capture_output=True, timeout=15)

    def test_target_change_routes_to_new_server(self):
        result = self.edit(("", "", "", str(self.echo_b.server_address[1]), "new target"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_forward(self.listen_port, b"B:payload")
        self.assert_forward(self.other_port, b"A:payload")

    def test_listen_port_change(self):
        port = free_port()
        result = self.edit(("", str(port), "", "", "new listen port"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_forward(port, b"A:payload")
        with self.assertRaises(OSError):
            socket.create_connection(("127.0.0.1", self.listen_port), timeout=.3)

    def test_occupied_port_rolls_back_and_restores_traffic(self):
        with socket.socket() as blocker:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen()
            port = blocker.getsockname()[1]
            result = self.edit(("", str(port), "", "", "will fail to bind"))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("已恢复原配置和服务", result.stdout)
        self.assertEqual(self.config.read_text(), self.original)
        self.assert_forward(self.listen_port, b"A:payload")
        self.assert_forward(self.other_port, b"A:payload")

    def test_ipv6_listen_and_target(self):
        try:
            echo = self.echo_server(b"V6:", ipv6=True)
        except OSError:
            self.skipTest("IPv6 loopback is not available")
        port = free_port()
        result = self.edit(("::1", str(port), "::1", str(echo.server_address[1]), "IPv6"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_forward(port, b"V6:payload", host="::1")
        self.assert_forward(self.other_port, b"A:payload")
        self.assertEqual(tomllib.loads(self.config.read_text())["endpoints"][0]["listen"], f"[::1]:{port}")


for name, script in (("MainIntegration", "realm.sh"), ("ChinaIntegration", "CN/realm.sh"), ("PreviewIntegration", "test/realm.sh")):
    globals()[name] = type(name, (IntegrationCases, unittest.TestCase), {"script": script})


if __name__ == "__main__":
    unittest.main()
