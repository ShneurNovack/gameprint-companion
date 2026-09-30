#!/usr/bin/env python3
"""Mock GamePrint backend implementing the companion API exactly as the real
Base44 functions do (poll marks delivered, ack records outcome), plus /control
endpoints the test script uses to inject faults.

Run: python3 mock_server.py --port 18080
"""
import argparse, html, json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEVICE = "TESTDEVICE01"
TOKEN = "TESTTOKEN0123456789ABCDEFGHIJKLM"
lock = threading.Lock()
jobs = []          # dicts in sequence order
seq = [0]
fault = {"down_until": 0, "ack_lose_response": 0, "ack_fail": 0, "poll_duplicate": 0}
stats = {"heartbeats": 0, "polls": 0, "acks": [], "auth_fail": 0}

TEMPLATE = open(__file__.replace("mock_server.py", "sample_page.html")).read()

def render(headline, away, home, sa, sh, desc, job_id):
    return (TEMPLATE.replace("{{HEADLINE}}", html.escape(headline)).replace("{{AWAY}}", away)
            .replace("{{HOME}}", home).replace("{{SA}}", str(sa)).replace("{{SH}}", str(sh))
            .replace("{{DESC}}", html.escape(desc)).replace("{{JOBID}}", html.escape(job_id)))

def enqueue(n=1, game="G1", event_type="touchdown", malformed=None, away="JAX", home="KC"):
    out = []
    with lock:
        for _ in range(n):
            seq[0] += 1
            jid = f"{game}-{event_type}-{seq[0]}"
            j = {"job_id": jid, "id": f"rec{seq[0]}", "event_type": event_type,
                 "headline": f"{event_type.upper().replace('_', ' ')} #{seq[0]}",
                 "espn_event_id": game, "sequence": seq[0], "status": "queued", "acks": [],
                 "paper_size": "letter",
                 "event_data": {"awayTeam": {"abbr": away}, "homeTeam": {"abbr": home}}}
            j["rendered_html"] = render(j["headline"], away, home, seq[0] % 35, seq[0] % 28,
                                        f"Play {seq[0]} of game {game}. Job {jid}.", jid)
            if malformed == "no_html":
                j["rendered_html"] = ""
            elif malformed == "no_id":
                j["job_id"] = None
            elif malformed == "not_html":
                j["rendered_html"] = "%PDF-1.4 garbage"
            elif malformed == "bad_paper":
                j["paper_size"] = "tabloid-9000"
            jobs.append(j)
            out.append(jid)
    return out

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/control/state":
            with lock:
                self.send(200, {"jobs": [{k: v for k, v in j.items() if k != "rendered_html"} for j in jobs],
                                "stats": stats, "fault": fault})
        else:
            self.send(404, {"error": "nope"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        p = self.path
        if p.startswith("/control/"):
            return self.control(p[len("/control/"):], body)
        if time.time() < fault["down_until"]:
            return self.send(503, {"error": "service unavailable (simulated outage)"})
        if body.get("device_id") != DEVICE or body.get("auth_token") != TOKEN:
            stats["auth_fail"] += 1
            return self.send(401, {"error": "invalid credentials"})
        if p == "/functions/companionHeartbeat":
            stats["heartbeats"] += 1
            stats["last_heartbeat"] = body
            with lock:
                q = sum(1 for j in jobs if j["status"] == "queued")
            return self.send(200, {"ok": True, "queued": q})
        if p == "/functions/companionPoll":
            stats["polls"] += 1
            with lock:
                out = []
                for j in jobs:
                    if j["status"] == "queued" and len(out) < 50:
                        j["status"] = "delivered"
                        j["deliveries"] = j.get("deliveries", 0) + 1
                        out.append({k: j[k] for k in ("job_id", "id", "event_type", "headline", "rendered_html",
                                                       "event_data", "paper_size", "espn_event_id", "sequence")})
                if fault["poll_duplicate"] and out:
                    fault["poll_duplicate"] -= 1
                    out = out + out + out   # same jobs 3x in one response
            return self.send(200, {"jobs": out})
        if p == "/functions/companionAck":
            jid = body.get("job_id")
            with lock:
                j = next((x for x in jobs if x["job_id"] == jid), None)
                if fault["ack_fail"] > 0:
                    fault["ack_fail"] -= 1
                    return self.send(500, {"error": "simulated ack failure (not recorded)"})
                if not j:
                    return self.send(404, {"error": "job not found"})
                j["acks"].append(body.get("outcome"))
                j["status"] = "printed" if body.get("outcome") == "printed" else "failed"
                j["reason"] = body.get("reason")
                stats["acks"].append(jid)
                if fault["ack_lose_response"] > 0:
                    fault["ack_lose_response"] -= 1
                    return self.send(500, {"error": "simulated lost ack response (recorded)"})
            return self.send(200, {"ok": True})
        self.send(404, {"error": "unknown function"})

    def control(self, cmd, b):
        if cmd == "enqueue":
            ids = enqueue(b.get("n", 1), b.get("game", "G1"), b.get("event_type", "touchdown"), b.get("malformed"),
                          b.get("away", "JAX"), b.get("home", "KC"))
            return self.send(200, {"ids": ids})
        if cmd == "redeliver":   # server "accidentally" sends a job again
            with lock:
                for j in jobs:
                    if j["job_id"] in b.get("ids", []) or b.get("all"):
                        j["status"] = "queued"
            return self.send(200, {"ok": True})
        if cmd == "fault":
            with lock:
                for k, v in b.items():
                    fault[k] = time.time() + v if k == "down_until" else v
            return self.send(200, fault)
        if cmd == "reset":
            with lock:
                jobs.clear(); stats["acks"].clear(); stats["heartbeats"] = 0; stats["polls"] = 0
            return self.send(200, {"ok": True})
        self.send(404, {"error": "unknown control"})

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    a = ap.parse_args()
    print(f"mock GamePrint server on http://127.0.0.1:{a.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
