"""Upload rides to Strava. Standard library only - no extra packages.

One-time setup, which needs you because it is your account:

    venv/bin/python strava.py setup

It asks for the Client ID and Secret from https://www.strava.com/settings/api
(create an app there; set "Authorization Callback Domain" to localhost), opens
your browser to approve, and stores the tokens. After that uploads are
automatic and the refresh token keeps working indefinitely.
"""

import http.server
import json
import mimetypes
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
import webbrowser

CONFIG = os.path.expanduser("~/.config/wattline/strava.json")
REDIRECT_PORT = 51236
REDIRECT = f"http://localhost:{REDIRECT_PORT}/exchange"
SCOPE = "activity:write,activity:read"


def load():
    try:
        with open(CONFIG) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as fh:
        json.dump(cfg, fh, indent=2)
    os.chmod(CONFIG, 0o600)  # holds a refresh token


def configured():
    return bool(load().get("refresh_token"))


def _post(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as resp:
        return json.load(resp)


def access_token():
    """A valid token, refreshing it if the old one has expired."""
    cfg = load()
    if not cfg.get("refresh_token"):
        raise RuntimeError("Strava is not set up yet - run: python strava.py setup")
    if cfg.get("expires_at", 0) > time.time() + 60:
        return cfg["access_token"]

    fresh = _post(
        "https://www.strava.com/oauth/token",
        {
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "grant_type": "refresh_token",
            "refresh_token": cfg["refresh_token"],
        },
    )
    cfg.update(
        access_token=fresh["access_token"],
        refresh_token=fresh["refresh_token"],
        expires_at=fresh["expires_at"],
    )
    save(cfg)
    return cfg["access_token"]


def upload(path, name="Indoor ride", description="", trainer=True):
    """Push a TCX file to Strava. Returns the activity URL once processed."""
    token = access_token()
    boundary = uuid.uuid4().hex
    with open(path, "rb") as fh:
        content = fh.read()

    parts = []
    for key, value in [
        ("data_type", "tcx"),
        ("name", name),
        ("description", description),
        ("trainer", "1" if trainer else "0"),
    ]:
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n"
        )
    body = "".join(parts).encode()
    body += (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{os.path.basename(path)}"\r\n'
        f"Content-Type: {mimetypes.guess_type(path)[0] or 'application/octet-stream'}\r\n\r\n"
    ).encode()
    body += content + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        "https://www.strava.com/api/v3/uploads",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.load(resp)

    # Strava processes asynchronously; poll until it gives an id or an error.
    upload_id = result["id"]
    for _ in range(30):
        time.sleep(2)
        req = urllib.request.Request(
            f"https://www.strava.com/api/v3/uploads/{upload_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = json.load(resp)
        if status.get("error"):
            raise RuntimeError(status["error"])
        if status.get("activity_id"):
            return f"https://www.strava.com/activities/{status['activity_id']}"
    raise RuntimeError("Strava is still processing; check your feed in a minute")


class _Catcher(http.server.BaseHTTPRequestHandler):
    code = None

    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        _Catcher.code = params.get("code", [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        message = "Connected. You can close this tab." if _Catcher.code else "No code returned."
        self.wfile.write(f"<h2>{message}</h2>".encode())

    def log_message(self, *args):
        pass


def setup():
    cfg = load()
    print("Create an app at https://www.strava.com/settings/api")
    print('Set "Authorization Callback Domain" to: localhost\n')
    client_id = input("Client ID: ").strip()
    client_secret = input("Client Secret: ").strip()

    server = http.server.HTTPServer(("localhost", REDIRECT_PORT), _Catcher)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    url = "https://www.strava.com/oauth/authorize?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "approval_prompt": "auto",
            "scope": SCOPE,
        }
    )
    print("\nOpening Strava to approve access...")
    webbrowser.open(url)

    for _ in range(120):
        if _Catcher.code:
            break
        time.sleep(1)
    server.shutdown()
    if not _Catcher.code:
        print("Timed out waiting for approval.")
        return 1

    tokens = _post(
        "https://www.strava.com/oauth/token",
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "code": _Catcher.code,
            "grant_type": "authorization_code",
        },
    )
    cfg.update(
        client_id=client_id,
        client_secret=client_secret,
        access_token=tokens["access_token"],
        refresh_token=tokens["refresh_token"],
        expires_at=tokens["expires_at"],
    )
    save(cfg)
    athlete = tokens.get("athlete", {})
    print(f"\nConnected as {athlete.get('firstname', '')} {athlete.get('lastname', '')}".rstrip())
    print("Rides will upload automatically from now on.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "setup":
        sys.exit(setup())
    if len(sys.argv) > 2 and sys.argv[1] == "upload":
        print(upload(sys.argv[2]))
        sys.exit(0)
    print(__doc__)
    print("configured:", configured())
