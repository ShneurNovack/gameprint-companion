#!/usr/bin/env python3
"""End-to-end reliability suite. Runs the real PrintEngine (via gpctl run)
against mock_server.py and a fake socket printer registered in CUPS as
GamePrint_Fake, then checks what physically reached the "printer".

Usage (from repo root, after `swift build`):
  python3 testing/e2e.py
Requires: mock_server.py on :18080, fake_printer.py on :19100 logging to
/tmp/fp.jsonl, and the CUPS queue GamePrint_Fake -> socket://127.0.0.1:19100.
"""
import collections, json, os, shutil, signal, sqlite3, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GPCTL = os.path.join(ROOT, ".build/debug/gpctl")
HOME = "/tmp/gp-e2e"
SERVER = "http://127.0.0.1:18080"
FP_LOG = "/tmp/fp.jsonl"
PRINTER = "GamePrint_Fake"
results = []
engine = None

def ctl(cmd, body=None):
    req = urllib.request.Request(f"{SERVER}/control/{cmd}", data=json.dumps(body or {}).encode(),
                                 method="POST" if body is not None else "GET")
    return json.loads(urllib.request.urlopen(req, timeout=5).read())

def state():
    return json.loads(urllib.request.urlopen(f"{SERVER}/control/state", timeout=5).read())

def printed():
    c = collections.Counter()
    order = []
    if os.path.exists(FP_LOG):
        for line in open(FP_LOG):
            r = json.loads(line)
            if r.get("job"):
                c[r["job"]] += 1
                order.append(r["job"])
    return c, order

def start_engine(extra_env=None):
    global engine
    env = dict(os.environ, GP_HOME=HOME, GP_SERVER=SERVER, GP_PRINTER=PRINTER, GP_POLL="1",
               GP_DEVICE_ID="TESTDEVICE01", GP_AUTH_TOKEN="TESTTOKEN0123456789ABCDEFGHIJKLM", GP_QUIET="1")
    env.update(extra_env or {})
    engine = subprocess.Popen([GPCTL, "run"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)

def stop_engine(hard=False):
    global engine
    if engine:
        engine.send_signal(signal.SIGKILL if hard else signal.SIGTERM)
        engine.wait(10)
        engine = None

def wait_for(pred, timeout=120, step=1):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return False

def server_jobs(prefix=None):
    return [j for j in state()["jobs"] if prefix is None or (j["job_id"] or "").startswith(prefix)]

def all_acked(ids):
    js = {j["job_id"]: j for j in state()["jobs"]}
    return all(js[i]["status"] in ("printed", "failed") for i in ids)

def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)

def set_config(**kw):
    p = os.path.join(HOME, "config.json")
    cfg = json.load(open(p)) if os.path.exists(p) else {}
    cfg.update(kw)
    json.dump(cfg, open(p, "w"))

def db():
    return sqlite3.connect(os.path.join(HOME, "jobs.sqlite"))

def main():
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(HOME)
    open(FP_LOG, "w").close()
    ctl("reset", {})
    set_config(setupComplete=True, autoResumePrinterQueue=True)

    # 1. basic delivery
    start_engine()
    ids = ctl("enqueue", {"n": 3, "game": "G1"})["ids"]
    ok = wait_for(lambda: all_acked(ids), 90)
    c, _ = printed()
    check("1 basic: 3 jobs printed once and acked printed",
          ok and all(c[i] == 1 for i in ids) and all(j["acks"] == ["printed"] for j in server_jobs("G1")), str(dict(c)))

    # 2a. server re-delivers already printed jobs
    ctl("redeliver", {"ids": ids})
    time.sleep(8)
    c, _ = printed()
    reacked = all(len(j["acks"]) >= 2 for j in server_jobs("G1"))
    check("2a duplicate re-delivery does not reprint (and is re-acknowledged)", all(c[i] == 1 for i in ids) and reacked, str(dict(c)))

    # 2b. same job 3x inside one poll response
    ctl("fault", {"poll_duplicate": 1})
    ids2 = ctl("enqueue", {"n": 2, "game": "G1B"})["ids"]
    wait_for(lambda: all_acked(ids2), 60)
    time.sleep(3)
    c, _ = printed()
    check("2b duplicate within a single poll prints once", all(c[i] == 1 for i in ids2), str({i: c[i] for i in ids2}))

    # 3. malformed jobs
    bad = []
    for kind in ("no_html", "not_html", "bad_paper"):
        bad += ctl("enqueue", {"n": 1, "game": "BAD", "malformed": kind})["ids"]
    ctl("enqueue", {"n": 1, "game": "BAD", "malformed": "no_id"})
    wait_for(lambda: all_acked(bad), 30)
    c, _ = printed()
    js = {j["job_id"]: j for j in state()["jobs"]}
    check("3 malformed jobs are not printed and are acked failed with a reason",
          all(js[i]["status"] == "failed" and js[i].get("reason") and c[i] == 0 for i in bad),
          "; ".join(f"{i}: {js[i].get('reason')}" for i in bad))

    # 4. multiple simultaneous games + 60 queued pages
    ids_g = []
    for k in range(20):
        for g in ("GA", "GB", "GC"):
            ids_g += ctl("enqueue", {"n": 1, "game": g})["ids"]
    ok = wait_for(lambda: all_acked(ids_g), 400, 2)
    c, order = printed()
    in_order = True
    for g in ("GA", "GB", "GC"):
        seqs = [int(x.rsplit("-", 1)[1]) for x in order if x.startswith(g + "-")]
        in_order &= seqs == sorted(seqs)
    check("4 60 pages across 3 simultaneous games: all printed once, per-game order kept",
          ok and all(c[i] == 1 for i in ids_g) and in_order, f"printed={sum(c[i] for i in ids_g)}/60 ordered={in_order}")

    # 5. backend outage
    ctl("fault", {"down_until": 25})
    time.sleep(3)
    ids5 = ctl("enqueue", {"n": 3, "game": "OUT"})["ids"]
    ok = wait_for(lambda: all_acked(ids5), 150)
    c, _ = printed()
    check("5 backend outage (25s of 503s) recovers and prints", ok and all(c[i] == 1 for i in ids5))

    # 6. ack failures: response lost after recording, and hard failures
    ctl("fault", {"ack_lose_response": 2, "ack_fail": 2})
    ids6 = ctl("enqueue", {"n": 3, "game": "ACK"})["ids"]
    ok = wait_for(lambda: all_acked(ids6), 150)
    time.sleep(12)
    c, _ = printed()
    con = db()
    pending = con.execute("select count(*) from jobs where ack_needed=1").fetchone()[0]
    check("6 ack failures are retried until settled, never reprinted",
          ok and all(c[i] == 1 for i in ids6) and pending == 0, f"pending acks={pending}")

    # 7. crash (SIGKILL) mid-queue, then restart
    ids7 = ctl("enqueue", {"n": 12, "game": "CRASH"})["ids"]
    wait_for(lambda: sum(1 for i in ids7 if printed()[0][i] >= 1) >= 3, 60, 0.3)
    stop_engine(hard=True)
    mid = sum(1 for i in ids7 if printed()[0][i] >= 1)
    start_engine()
    ok = wait_for(lambda: all_acked(ids7), 150)
    time.sleep(3)
    c, order = printed()
    seqs = [int(x.rsplit("-", 1)[1]) for x in order if x.startswith("CRASH-")]
    check("7 crash mid-queue: nothing lost, nothing doubled, order kept",
          ok and all(c[i] == 1 for i in ids7) and seqs == sorted(seqs), f"printed before kill={mid}")

    # 8. crash in the submit window: job reached CUPS but state still 'submitting'
    stop_engine()
    con = db()
    jid = ids7[-1]
    con.execute("update jobs set state='submitting', ack_needed=0 where job_id=?", (jid,))
    con.commit(); con.close()
    start_engine()
    time.sleep(10)
    c, _ = printed()
    con = db()
    st = con.execute("select state from jobs where job_id=?", (jid,)).fetchone()[0]
    check("8 crash between CUPS submit and DB update is recovered without reprint", c[jid] == 1 and st == "printed", f"state={st}")

    # 9. pause keeps accepting jobs; resume prints them in order
    stop_engine()
    set_config(paused=True)
    start_engine()
    ids9 = ctl("enqueue", {"n": 4, "game": "PAUSE"})["ids"]
    time.sleep(8)
    c, _ = printed()
    con = db()
    queued = con.execute("select count(*) from jobs where job_id like 'PAUSE-%' and state='queued'").fetchone()[0]
    paused_ok = all(c[i] == 0 for i in ids9) and queued == 4
    stop_engine()
    set_config(paused=False)
    start_engine()
    ok = wait_for(lambda: all_acked(ids9), 90)
    c, order = printed()
    seqs = [int(x.rsplit("-", 1)[1]) for x in order if x.startswith("PAUSE-")]
    check("9 pause accepts but holds jobs; resume prints them in order",
          paused_ok and ok and all(c[i] == 1 for i in ids9) and seqs == sorted(seqs), f"held while paused={queued}")

    # 10. printer offline then back
    subprocess.run(["pkill", "-f", "fake_printer.py"])
    time.sleep(1)
    ids10 = ctl("enqueue", {"n": 3, "game": "OFFLINE"})["ids"]
    time.sleep(20)
    c, _ = printed()
    none_yet = all(c[i] == 0 for i in ids10)
    js = {j["job_id"]: j for j in state()["jobs"]}
    not_acked = all(js[i]["status"] == "delivered" for i in ids10)
    subprocess.Popen(["python3", os.path.join(ROOT, "testing/fake_printer.py"), "--port", "19100", "--log", FP_LOG],
                     stdout=open("/tmp/fp.out", "a"), stderr=subprocess.STDOUT, start_new_session=True)
    ok = wait_for(lambda: all_acked(ids10), 240, 2)
    c, _ = printed()
    check("10 printer offline: jobs wait (not acked as printed), print once when it returns",
          none_yet and not_acked and ok and all(c[i] == 1 for i in ids10) and
          all(j["acks"] == ["printed"] for j in server_jobs("OFFLINE")))

    stop_engine()
    total = collections.Counter(printed()[0])
    dups = {k: v for k, v in total.items() if v > 1}
    check("ALL no job printed more than once across the whole run", not dups, str(dups))
    print("\nSUMMARY: %d/%d passed" % (sum(1 for r in results if r[1]), len(results)))
    return 0 if all(r[1] for r in results) else 1

if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        stop_engine()
