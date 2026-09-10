#!/usr/bin/env bash
# Probe the side_question control request against the real CLI and record it.
#
#   scripts/record-side-question.sh --out test/fixtures/side-question.jsonl
#
# The side question is the /btw of the terminal client.  It is not a slash
# command: it is a control request the SDK sends over the same stream-json
# channel ecc already speaks.  This script settles what the
# binary only suggested:
#
#   1. a plain turn, so that there is a conversation to ask about
#   2. one side question, to see the progress and the answer
#   3. a second one carrying `history', to see whether the context threads
#   4. a side question sent while a turn is running, to see that the turn
#      is not interrupted and both answers come back
#   5. a side question cancelled with control_cancel_request
#
# Every line of stdout goes to OUT as it is.  As the development rules
# (CLAUDE.md) require, --model haiku and --max-budget-usd are always passed
# and any plugin named with --disable-plugin is turned off.  Persistence
# is on by default here, unlike record-fixture.sh: whether the answer
# reaches ~/.claude/projects is one of the things being measured.
set -euo pipefail
exec python3 - "$@" <<'EOF'
import argparse, json, os, subprocess, sys, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="test/fixtures/side-question.jsonl")
ap.add_argument("--timeout", type=float, default=300.0)
ap.add_argument("--model", default="haiku")
ap.add_argument("--budget", default="0.5")
ap.add_argument("--no-persist", action="store_true",
                help="pass --no-session-persistence; without it the recording "
                     "in ~/.claude/projects can be diffed afterwards")
ap.add_argument("--disable-plugin", action="append",
                default=[])
ap.add_argument("extra", nargs="*")
args = ap.parse_args()

cmd = ["claude", "-p",
       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--permission-prompt-tool", "stdio",
       "--model", args.model, "--max-budget-usd", args.budget]
if args.no_persist:
    cmd += ["--no-session-persistence"]
if args.disable_plugin:
    cmd += ["--settings",
            json.dumps({"enabledPlugins": {p: False for p in args.disable_plugin}})]
cmd += args.extra
print("$", " ".join(cmd), file=sys.stderr)

out = open(args.out, "w")
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, bufsize=1)
deadline = time.time() + args.timeout


def send(obj):
    print(f"  <- {json.dumps(obj, ensure_ascii=False)[:120]}", file=sys.stderr)
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()


def send_user(text):
    send({"type": "user", "message": {"role": "user", "content": text}})


def side_question(question, history=None):
    """Send a side_question control request and return its request id."""
    rid = str(uuid.uuid4())
    request = {"subtype": "side_question", "question": question}
    if history:
        request["history"] = history
    send({"type": "control_request", "request_id": rid, "request": request})
    return rid


def cancel(rid):
    send({"type": "control_cancel_request", "request_id": rid})


def read():
    """Return the next parsed message, recording the raw line."""
    if time.time() > deadline:
        raise SystemExit("timed out")
    line = p.stdout.readline()
    if not line:
        raise SystemExit("the CLI closed its stdout")
    out.write(line)
    out.flush()
    try:
        return json.loads(line)
    except Exception:
        return {}


findings = {}
progress = []
answers = {}


def pump(until):
    """Read until UNTIL says to stop, noting progress and control responses."""
    while True:
        o = read()
        kind = o.get("type")
        if kind == "system" and o.get("subtype") == "control_request_progress":
            progress.append(o)
            print(f"  -> progress {o.get('status')} {o.get('request_id', '')[:8]}",
                  file=sys.stderr)
        elif kind == "control_response":
            inner = o.get("response", {})
            rid = inner.get("request_id")
            answers[rid] = inner
            print(f"  -> response {inner.get('subtype')} {str(rid)[:8]}: "
                  f"{json.dumps(inner.get('response') or inner.get('error'), ensure_ascii=False)[:160]}",
                  file=sys.stderr)
        elif kind == "result":
            print("  -> result", file=sys.stderr)
        if until(o):
            return o


def answered(rid):
    return lambda o: rid in answers


def result_seen(o):
    return o.get("type") == "result"


# 1. A plain turn, so that there is something to ask about.
print("== turn 1", file=sys.stderr)
send_user("Remember the number 4271. Just say OK.")
pump(result_seen)

# 2. One side question.
print("== side question 1", file=sys.stderr)
q1 = "What number did I ask you to remember?"
rid1 = side_question(q1)
pump(answered(rid1))
a1 = answers[rid1]
findings["shares the conversation"] = a1
findings["progress before the answer"] = [
    o.get("status") for o in progress if o.get("request_id") == rid1]

# 3. A second one, threading the first through `history'.
print("== side question 2 (with history)", file=sys.stderr)
response1 = (a1.get("response") or {}).get("response")
rid2 = side_question(
    "And what did I ask you about it just now, in my previous side question?",
    history=[{"question": q1, "response": response1 or ""}])
pump(answered(rid2))
findings["history threads"] = answers[rid2]

# 4. One asked while a turn is running: the turn must not be interrupted.
print("== side question 3 (while a turn runs)", file=sys.stderr)
send_user("Count slowly from 1 to 20, one line each, with a short remark on every number.")
# Give the turn a moment to be under way before asking beside it.
o = read()
rid3 = side_question("In one word: what number am I counting to?")
saw_answer_before_result = None
while True:
    o = pump(lambda o: o.get("type") == "result" or rid3 in answers)
    if saw_answer_before_result is None:
        saw_answer_before_result = rid3 in answers
    if rid3 in answers and o.get("type") == "result":
        break
    if rid3 in answers:
        pump(result_seen)
        break
    if o.get("type") == "result":
        pump(answered(rid3))
        break
findings["answered beside a running turn"] = answers[rid3]
findings["the answer came before the turn ended"] = saw_answer_before_result

# 5. One cancelled straight away.
print("== side question 4 (cancelled)", file=sys.stderr)
rid4 = side_question("Write a long essay about the number 4271.")
cancel(rid4)
try:
    pump(answered(rid4))
    findings["cancel"] = answers[rid4]
except SystemExit as error:
    findings["cancel"] = f"nothing came back: {error}"

p.stdin.close()
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
out.close()

print("\n== findings", file=sys.stderr)
print(json.dumps(findings, ensure_ascii=False, indent=2), file=sys.stderr)
print(f"\nwrote {args.out} ({os.path.getsize(args.out)} bytes)", file=sys.stderr)
EOF
