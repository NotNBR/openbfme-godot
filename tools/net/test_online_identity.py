"""Asset-free install identity persistence and the client-side device hash."""
import os
import http.server
import json
import re
import shutil
import subprocess
import threading
from pathlib import Path

import pytest


def test_identity_persists_and_hashes_without_sending_machine_id(tmp_path):
    godot = os.environ.get("GODOT", "godot")
    if not shutil.which(godot):
        pytest.skip("SKIP LOUDLY: Godot is needed for the install identity test")
    repo = Path(__file__).resolve().parents[2]
    env = dict(os.environ, HOME=str(tmp_path), XDG_DATA_HOME=str(tmp_path / "data"),
               XDG_CONFIG_HOME=str(tmp_path / "config"))
    env.pop("ROTWK_INSTALL", None)
    env.pop("BFME2_INSTALL", None)
    result = subprocess.run([godot, "--headless", "--path", str(repo / "godot"), "--script",
                             "res://tests/online_identity_test.gd"], env=env, capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "IDENTITY PASS" in output, output


def test_guest_signin_sends_persistent_identity_and_receives_notice(tmp_path):
    godot = os.environ.get("GODOT", "godot")
    if not shutil.which(godot):
        pytest.skip("SKIP LOUDLY: Godot is needed for the sign-in test")
    seen = []

    class Lobby(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            if self.path == "/v1/auth/guest":
                seen.append(body)
                status = 200
                answer = {"v": 1, "token": "test-session-token", "account": {"name": "IdentityTest", "kind": "guest"},
                          "notice": {"id": "N-1", "text": "A pending warning"}}
            else:
                status = 403
                answer = {"v": 1, "error": "suspended", "message": "Test complete"}
            data = json.dumps(answer).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Lobby)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    repo = Path(__file__).resolve().parents[2]
    env = dict(os.environ, HOME=str(tmp_path), XDG_DATA_HOME=str(tmp_path / "data"),
               XDG_CONFIG_HOME=str(tmp_path / "config"))
    env.pop("ROTWK_INSTALL", None)
    env.pop("BFME2_INSTALL", None)
    try:
        for _ in range(2):
            result = subprocess.run([godot, "--headless", "--path", str(repo / "godot"), "--script",
                                     "res://tests/online_identity_test.gd", "--",
                                     f"--lobby=http://127.0.0.1:{server.server_port}"], env=env,
                                    capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert "IDENTITY SIGNIN PASS" in output, output
        assert len(seen) == 2
        assert seen[0] == seen[1]
        assert re.fullmatch(r"[0-9a-f]{32}", seen[0]["install"])
        if "device" in seen[0]:
            assert re.fullmatch(r"[0-9a-f]{64}", seen[0]["device"])
        assert seen[0]["client"]["platform"]
        assert seen[0]["client"]["version"]
    finally:
        server.shutdown()
        server.server_close()
