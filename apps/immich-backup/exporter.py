"""Prometheus exporter for the Immich backup bucket on Backblaze B2.

B2 has no metrics endpoint, so this walks b2_list_file_versions every REFRESH_SECONDS
and reports, per top-level prefix, the bytes and file counts of current versions and
of noncurrent ones (hidden or superseded versions waiting for the lifecycle rules).
List calls are free on B2. Only the totals are kept in memory, never the listing.
"""

import base64
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY_ID = os.environ["B2_APPLICATION_KEY_ID"]
KEY = os.environ["B2_APPLICATION_KEY"]
BUCKET = os.environ["B2_BUCKET"]
# Prefixes always exported, so the series exist (as 0) before anything is uploaded.
PREFIXES = [p for p in os.environ.get("B2_PREFIXES", "").split(",") if p]
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", "900"))
RETRY_SECONDS = int(os.environ.get("RETRY_SECONDS", "300"))
PORT = int(os.environ.get("PORT", "9101"))

STATES = ("current", "noncurrent")

lock = threading.Lock()
snapshot = {"body": "", "success": 0, "last_success": 0.0, "duration": 0.0}


def log(msg):
    print(f"[b2-exporter] {msg}", flush=True)


def post(url, token, body):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Authorization": token, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def authorize():
    basic = base64.b64encode(f"{KEY_ID}:{KEY}".encode()).decode()
    req = urllib.request.Request(
        "https://api.backblazeb2.com/b2api/v3/b2_authorize_account",
        headers={"Authorization": f"Basic {basic}"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        auth = json.load(resp)
    return auth["accountId"], auth["apiInfo"]["storageApi"]["apiUrl"], auth["authorizationToken"]


def prefix_of(name):
    head, sep, _ = name.partition("/")
    return head + "/" if sep else "/"


def collect():
    account_id, api_url, token = authorize()
    buckets = post(
        f"{api_url}/b2api/v3/b2_list_buckets",
        token,
        {"accountId": account_id, "bucketName": BUCKET},
    )["buckets"]
    if not buckets:
        raise RuntimeError(f"bucket {BUCKET!r} not visible to this key")
    bucket_id = buckets[0]["bucketId"]

    files = {}  # (prefix, state) -> count
    size = {}  # (prefix, state) -> bytes
    hidden = {}  # prefix -> file names whose newest version is a hide marker
    last_upload = {}  # prefix -> newest upload timestamp (seconds)
    unfinished = 0
    for p in PREFIXES:
        hidden[p] = 0
        for s in STATES:
            files[(p, s)] = 0
            size[(p, s)] = 0

    # Versions come sorted by name, newest first. The first upload or hide seen for a
    # name decides it: an upload is the current version, a hide means the file was
    # removed. Every later upload of that name is noncurrent. "start" entries are
    # unfinished large files and do not decide anything.
    prev_name = None
    decided = False
    start = {}
    while True:
        page = post(
            f"{api_url}/b2api/v3/b2_list_file_versions",
            token,
            {"bucketId": bucket_id, "maxFileCount": 10000, **start},
        )
        for f in page["files"]:
            name = f["fileName"]
            if name != prev_name:
                prev_name, decided = name, False
            prefix = prefix_of(name)
            action = f["action"]
            if action == "start":
                unfinished += 1
            elif action == "hide":
                if not decided:
                    hidden[prefix] = hidden.get(prefix, 0) + 1
                decided = True
            elif action == "upload":
                state = "noncurrent" if decided else "current"
                decided = True
                files[(prefix, state)] = files.get((prefix, state), 0) + 1
                size[(prefix, state)] = size.get((prefix, state), 0) + f["contentLength"]
                ts = f["uploadTimestamp"] / 1000
                last_upload[prefix] = max(last_upload.get(prefix, 0), ts)
        if not page.get("nextFileName"):
            break
        start = {"startFileName": page["nextFileName"], "startFileId": page["nextFileId"]}

    b = f'bucket="{BUCKET}"'
    out = [
        "# HELP b2_bucket_bytes Bytes stored in the bucket, by top-level prefix and version state.",
        "# TYPE b2_bucket_bytes gauge",
    ]
    out += [f'b2_bucket_bytes{{{b},prefix="{p}",state="{s}"}} {v}' for (p, s), v in sorted(size.items())]
    out += [
        "# HELP b2_bucket_files File versions in the bucket, by top-level prefix and version state.",
        "# TYPE b2_bucket_files gauge",
    ]
    out += [f'b2_bucket_files{{{b},prefix="{p}",state="{s}"}} {v}' for (p, s), v in sorted(files.items())]
    out += [
        "# HELP b2_bucket_hidden_files File names whose newest version is a hide marker (removed from the source).",
        "# TYPE b2_bucket_hidden_files gauge",
    ]
    out += [f'b2_bucket_hidden_files{{{b},prefix="{p}"}} {v}' for p, v in sorted(hidden.items())]
    out += [
        "# HELP b2_bucket_last_upload_timestamp_seconds Upload time of the newest file version under the prefix.",
        "# TYPE b2_bucket_last_upload_timestamp_seconds gauge",
    ]
    out += [f'b2_bucket_last_upload_timestamp_seconds{{{b},prefix="{p}"}} {v:.3f}' for p, v in sorted(last_upload.items())]
    out += [
        "# HELP b2_bucket_unfinished_large_files Large file uploads started but never finished.",
        "# TYPE b2_bucket_unfinished_large_files gauge",
        f"b2_bucket_unfinished_large_files{{{b}}} {unfinished}",
    ]
    return "\n".join(out) + "\n"


def refresh_loop():
    while True:
        started = time.time()
        try:
            body = collect()
            with lock:
                snapshot.update(body=body, success=1, last_success=time.time(), duration=time.time() - started)
            log(f"collected in {time.time() - started:.1f}s")
            delay = REFRESH_SECONDS
        except (urllib.error.URLError, OSError, KeyError, ValueError, RuntimeError) as err:
            # Keep serving the last good numbers; b2_exporter_collect_success shows the failure.
            with lock:
                snapshot.update(success=0, duration=time.time() - started)
            log(f"collect failed: {err}")
            delay = RETRY_SECONDS
        time.sleep(delay)


def render():
    b = f'bucket="{BUCKET}"'
    with lock:
        s = dict(snapshot)
    return s["body"] + "\n".join(
        [
            "# HELP b2_exporter_collect_success Whether the last bucket listing succeeded.",
            "# TYPE b2_exporter_collect_success gauge",
            f"b2_exporter_collect_success{{{b}}} {s['success']}",
            "# HELP b2_exporter_last_success_timestamp_seconds When the bucket was last listed successfully.",
            "# TYPE b2_exporter_last_success_timestamp_seconds gauge",
            f"b2_exporter_last_success_timestamp_seconds{{{b}}} {s['last_success']:.3f}",
            "# HELP b2_exporter_collect_duration_seconds Duration of the last bucket listing.",
            "# TYPE b2_exporter_collect_duration_seconds gauge",
            f"b2_exporter_collect_duration_seconds{{{b}}} {s['duration']:.3f}",
        ]
    ) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            payload = render().encode()
            ctype = "text/plain; version=0.0.4; charset=utf-8"
        elif self.path == "/healthz":
            payload, ctype = b"ok\n", "text/plain"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=refresh_loop, daemon=True).start()
    log(f"serving :{PORT}, bucket {BUCKET}, refresh every {REFRESH_SECONDS}s")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
