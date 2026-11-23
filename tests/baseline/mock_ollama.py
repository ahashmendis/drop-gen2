#!/usr/bin/env python3
"""Scripted mock Ollama server for Drop pipeline characterization tests.
Serves GET /api/tags and POST /api/generate. Each generate call returns the
next scripted response of the chosen scenario and appends the request
(prompt, model, options) to a JSON-lines log, with temp paths normalised.
usage: mock_ollama.py <port> <scenario> <log-file>
"""
import json, re, sys, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
J = lambda n: open(os.path.join(HERE, "fixtures", "java", n)).read().rstrip("\n")
PKG = "src/main/java/edu/practice/parking/"

def block(files, task=1):
    out = "// ===== Task %d =====\n" % task
    for name, path in files:
        out += "// ===== FILE: %s%s =====\n%s\n" % (PKG, path, J(name))
    return out

ALL = [("HourlyPass.java", "model/HourlyPass.java"), ("WeekendPass.java", "model/WeekendPass.java"),
       ("PassRepository.java", "repo/PassRepository.java"), ("ParkingService.java", "service/ParkingService.java"),
       ("ParkingController.java", "controller/ParkingController.java"),
       ("ApiExceptionHandler.java", "error/ApiExceptionHandler.java")]
ALL_BROKEN = [("HourlyPass_broken.java", "model/HourlyPass.java")] + ALL[1:]
FIX = [("HourlyPass.java", "model/HourlyPass.java")]

def ok(text, reason="stop"): return {"text": text, "done_reason": reason}

SCENARIOS = {
  # First answer compiles: no repair round.
  "pass": [ok(block(ALL))],
  # Compile error, then a targeted repair that fixes it.
  "repair": [ok(block(ALL_BROKEN)), ok(block(FIX))],
  # Answer cut mid-file by the context (done_reason length), completed by repair.
  "truncated": [ok(block(ALL)[:block(ALL).index("public class ParkingService") + 400], "length"),
                ok(block([("ParkingService.java", "service/ParkingService.java")]))],
  # Never gets fixed: distinct broken repairs until the 4-round cap.
  "never_fixed": [ok(block(ALL_BROKEN))] + [ok(block([("HourlyPass_broken.java", "model/HourlyPass.java")]) + "// try %d" % i) for i in range(1, 6)],
  # Server error: pipeline must stop cleanly with no answer.
  "http500": [{"status": 500, "error": "mock failure"}],
}

def acd_bench_answer(mode):
    """Answer for the ACD mock ICT built from its task.json key. mode: ref | mutant | broken."""
    import json
    t = json.load(open(os.path.join(os.environ["BENCH_TASKS_DIR"], "acd-mock-ict", "task.json")))
    key = {r["id"]: r["answer"] for r in t["requirements"] if r["kind"] == "objective"}
    flips = {"A3": "C", "B3": "True", "E2": "B"}
    out = []
    def sect(n, title): out.append("// ===== Task %d =====" % n)
    sec = {"A": 1, "B": 2, "E": 5}
    emitted = set()
    for qid in [r["id"] for r in t["requirements"] if r["kind"] == "objective"]:
        letter = qid[0]
        if mode == "broken" and letter in ("B", "E"): continue
        if letter not in emitted: out.append("// ===== Task %d =====" % sec[letter]); emitted.add(letter)
        ans = flips.get(qid, key[qid]) if mode == "mutant" else key[qid]
        out.append("// ===== Q %s =====\n%s" % (qid, ans))
    out.append("// ===== Task 3 =====")
    if mode == "mutant":
        c1 = "```js\nconst prices = [15, 25, 10, 30];\nconst total = prices.reduce((sum, p) => sum * p, 1);\n```"
        c2 = "```ts\ninterface Product { id: number; name: string; price?: number; description?: string }\n```"
        c4 = "Call queryClient.invalidateQueries({ queryKey: ['customers'] })."
    else:
        c1 = "```js\nconst prices = [15, 25, 10, 30];\nconst total = prices.reduce((sum, price) => sum + price, 0);\n```"
        c2 = "```ts\ninterface Product {\n  id: number;\n  name: string;\n  price: number;\n  description?: string;\n}\n```"
        c4 = "invalidateQueries() marks the cached customer queries as stale so active queries refetch fresh data."
    out.append("// ===== Q C1 =====\n" + c1)
    out.append("// ===== Q C2 =====\n" + c2)
    out.append("// ===== Q C3 =====\nuseParams(): const { orderId } = useParams();")
    out.append("// ===== Q C4 =====\n" + c4)
    out.append("// ===== Q C5 =====\n401 means not authenticated; 403 means authenticated but not permitted.")
    out.append("// ===== Task 4 =====")
    for q in ("D1", "D2", "D3", "D4"): out.append("// ===== Q %s =====\nSee explanation for %s." % (q, q))
    return "\n".join(out) + "\n"

def bench_response(req):
    """scenario 'bench': answer from BENCH_SOL_DIR/<modelkey>/<task>[_fix]/src/main/java/** (model = qwen-<key>:...)."""
    sol = os.environ["BENCH_SOL_DIR"]
    prompt = req.get("prompt", "")
    key = req["model"].split(":")[0].replace("qwen-", "")
    if "Advanced Client-Side Development" in prompt:
        return ok(acd_bench_reply(prompt, key))
    task = ("simple-parking" if "edu.practice.parking" in prompt else "moderate-dispatch" if "edu.practice.dispatch" in prompt
            else "extreme-scheduler" if "edu.practice.scheduler" in prompt else None)
    if task is None: return ok("// no task recognised")
    repair = "JAVAC ERRORS" in prompt and "AFFECTED FILES" in prompt
    d = os.path.join(sol, key, task + ("_fix" if repair else ""))
    if repair and not os.path.isdir(d): d = os.path.join(sol, key, task)
    out = "// ===== Task 1 =====\n"
    for root, _, files in sorted(os.walk(d)):
        for f in sorted(files):
            if f.endswith(".java"):
                full = os.path.join(root, f); rel = os.path.relpath(full, d)
                out += "// ===== FILE: %s =====\n%s\n" % (rel, open(full).read().rstrip("\n"))
    return ok(out)

ACD_HELLO_OK = "import { useState } from 'react';\nexport function Hello() {\n  const [n, setN] = useState(0);\n  return <button onClick={() => setN(n + 1)}>{n}</button>;\n}"
ACD_D1_TEXT = "The Outlet renders the matched child route inside the shared layout.\n"
ACD_D1_GOOD = ACD_D1_TEXT + "// ===== FILE: src/components/Hello.tsx =====\n" + ACD_HELLO_OK + "\n// ===== FILE: src/components/Keep.tsx =====\nexport const keep = 1;\n"
ACD_D1_BAD = ACD_D1_TEXT + "// ===== FILE: src/components/Hello.tsx =====\nexport const n: number = \"x\";\n// ===== FILE: src/components/Keep.tsx =====\nexport const keep = 1;\n"
ACD_WORSE = "// ===== FILE: src/components/Hello.tsx =====\nexport const n: number = \"x\";\nexport const m: string = 5;\n"
ACD_FIX = "// ===== FILE: src/components/Hello.tsx =====\n" + ACD_HELLO_OK + "\n"

def oop_think_empty_response(req):
    """The thinking-on request burns its budget and returns nothing; the no-thinking retry answers."""
    if req.get("think") is True: return {"text": "", "done_reason": "length"}
    return ok(block(ALL))

def pertask_response(req, scen):
    """OOP per-task: answer 'Write ONLY Task N now' with that task's files of the SIMPLE reference solution."""
    prompt = req.get("prompt", "")
    m = re.search(r"Write ONLY Task (\d+) now", prompt)
    if not m: return ok("// no per-task request recognised")
    n = int(m.group(1))
    parts = {1: [("HourlyPass.java", "model/HourlyPass.java")], 2: [("WeekendPass.java", "model/WeekendPass.java"), ("PassRepository.java", "repo/PassRepository.java")],
             3: [("ParkingService.java", "service/ParkingService.java"), ("ApiExceptionHandler.java", "error/ApiExceptionHandler.java")], 4: [("ParkingController.java", "controller/ParkingController.java")]}
    return ok(block(parts.get(n, []), n))

def acd_response(req, scen, calls):
    prompt = req.get("prompt", "")
    if scen == "acd_500": return {"status": 500, "error": "mock failure"}
    if "Reply with ONLY the letter" in prompt: return ok("B")
    if "Reply with ONLY True or False" in prompt: return ok("False")
    repair = "ORIGINAL TASK REQUIREMENTS" in prompt
    if scen == "acd_pass": return ok(ACD_D1_GOOD)
    if scen == "acd_repair": return ok(ACD_FIX if repair else ACD_D1_BAD)
    if scen == "acd_never": return ok(ACD_WORSE if repair else ACD_D1_BAD)
    return ok("// unknown scenario")

def acd_bench_reply(prompt, mode):
    """Per-question reply for the ACD mock ICT. mode: ref | mutant | broken."""
    import json
    t = json.load(open(os.path.join(os.environ["BENCH_TASKS_DIR"], "acd-mock-ict", "task.json")))
    key = {r["id"]: r["answer"] for r in t["requirements"] if r["kind"] == "objective"}
    m = re.search(r"QUESTION\n([A-E]\d{1,2})\.", prompt)
    qid = m.group(1) if m else ""
    if "Reply with ONLY" in prompt:
        if mode == "broken" and qid[:1] in ("B", "E"): return "Hmm, it depends."
        flips = {"A3": "C", "B3": "True", "E2": "B"}
        return flips.get(qid, key.get(qid, "A")) if mode == "mutant" else key.get(qid, "A")
    if qid == "C1":
        return ("```js\nconst prices = [15, 25, 10, 30];\nconst total = prices.reduce((sum, p) => sum * p, 1);\n```" if mode == "mutant" else
                "```js\nconst prices = [15, 25, 10, 30];\nconst total = prices.reduce((sum, price) => sum + price, 0);\n```")
    if qid == "C2":
        return ("```ts\ninterface Product { id: number; name: string; price?: number; description?: string }\n```" if mode == "mutant" else
                "```ts\ninterface Product {\n  id: number;\n  name: string;\n  price: number;\n  description?: string;\n}\n```")
    if qid == "C3": return "useParams(): const { orderId } = useParams();"
    if qid == "C4": return ("Call queryClient.invalidateQueries({ queryKey: ['customers'] })." if mode == "mutant" else
                            "invalidateQueries() marks the cached customer queries as stale so active queries refetch fresh data.")
    if qid == "C5": return "401 means not authenticated; 403 means authenticated but not permitted."
    return "See explanation for %s." % qid

def norm(s):
    return re.sub(r"/[^\s\"']*dropc-[0-9A-Fa-f-]+", "<TMP>", s)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls = 0
    def log_message(self, *a): pass
    def do_GET(self):
        names = os.environ.get("MOCK_MODELS", "qwen-mock:1b").split(",")
        body = json.dumps({"models": [{"name": n, "model": n, "digest": "sha256:" + n.encode().hex() * 4,
                 "size": 1234, "details": {"family": "qwen3", "families": ["qwen3"], "parameter_size": "1B", "quantization_level": "Q4_K_M"}} for n in names]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        if req.get("keep_alive") == 0 and "prompt" not in req:
            with open(LOG, "a") as f: f.write(json.dumps({"unload": True, "model": req.get("model")}) + "\n")
            b = b"{}"; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        with open(LOG, "a") as f:
            f.write(json.dumps({"call": H.calls, "path": self.path, "model": req.get("model"),
                "options": req.get("options"), "think": req.get("think"), "keep_alive": req.get("keep_alive"),
                "stream": req.get("stream"), "prompt": norm(req.get("prompt", ""))}, sort_keys=True) + "\n")
        if SCEN == "oop_think_empty":
            resp = oop_think_empty_response(req); H.calls += 1
        elif SCEN.startswith("pertask"):
            resp = pertask_response(req, SCEN); H.calls += 1
        elif SCEN.startswith("acd_"):
            resp = acd_response(req, SCEN, H.calls); H.calls += 1
        elif SCEN == "bench":
            resp = bench_response(req); H.calls += 1
        else:
            script = SCENARIOS[SCEN]
            resp = script[min(H.calls, len(script) - 1)]; H.calls += 1
        if "status" in resp:
            b = json.dumps({"error": resp["error"]}).encode()
            self.send_response(resp["status"]); self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        text = resp["text"]
        if req.get("stream") is False:
            # Windows port (Drop.ps1) sends stream:false: one JSON object, same content as the streamed form.
            data = json.dumps({"response": text, "done": True, "done_reason": resp["done_reason"]}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        lines = [json.dumps({"response": text[i:i+200], "done": False}) for i in range(0, len(text), 200)]
        lines.append(json.dumps({"response": "", "done": True, "done_reason": resp["done_reason"]}))
        data = ("\n".join(lines) + "\n").encode()
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

if __name__ == "__main__":
    PORT, SCEN, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    open(LOG, "w").close()
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
