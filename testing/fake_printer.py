#!/usr/bin/env python3
"""Fake network printer: a raw JetDirect (socket://) listener. CUPS sends each
job as one connection; we record the job title from the PostScript/PDF so tests
can prove exactly which pages physically "printed" and how many times.

Run: python3 fake_printer.py --port 19100 --log /tmp/fakeprinter.jsonl
"""
import argparse, json, re, socket, threading, time

def serve(port, log):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)
    print(f"fake printer on socket://127.0.0.1:{port}", flush=True)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, log), daemon=True).start()

def handle(c, log):
    data = bytearray()
    c.settimeout(30)
    try:
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    except Exception:
        pass
    finally:
        c.close()
    text = data.decode("latin-1", "ignore")
    titles = re.findall(r"GamePrint ([^\s)#]+(?:#reprint-\d+)?) #\d+", text)
    m = re.search(r"%%Title:\s*(.*)", text)
    rec = {"t": time.time(), "bytes": len(data), "title": (m.group(1).strip() if m else None),
           "job": titles[0] if titles else None, "pages": text.count("%%Page:")}
    with open(log, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print("printed", rec, flush=True)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=19100)
    ap.add_argument("--log", default="/tmp/fakeprinter.jsonl")
    a = ap.parse_args()
    serve(a.port, a.log)
