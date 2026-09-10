#!/usr/bin/env bash
# Run the real CLI and record every stream-json line as a fixture.
#
#   scripts/record-fixture.sh --out test/fixtures/basic-turn.jsonl \
#       --prompt "hello" [--policy allow] [-- more claude options...]
#
# Every line of stdout goes to OUT as it is.  Control requests
# (can_use_tool) are answered the way --policy says.  As the development
# rules (CLAUDE.md) require, --model haiku and --max-budget-usd are always
# passed, and the emacs-gravity hooks are turned off with --settings.
set -euo pipefail
exec python3 - "$@" <<'EOF'
import argparse, json, subprocess, sys, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--prompt", action="append", required=True,
                help="prompt to send; give it more than once to send them in turn")
ap.add_argument("--policy", default="allow",
                choices=["allow", "deny-then-allow", "question", "plan", "none"])
ap.add_argument("--deny-message", default="内容を hi にして")
ap.add_argument("--answer-sep", default=", ",
                help="separator between multiSelect answers of AskUserQuestion")
ap.add_argument("--initialize", action="store_true", help="send initialize first")
ap.add_argument("--timeout", type=float, default=300.0)
ap.add_argument("--disable-plugin", action="append",
                default=["emacs-bridge@emacs-gravity-marketplace"],
                help="plugin to turn off for this session only.  Unlike "
                     "--safe-mode this keeps MCP, skills and commands "
                     "as well")
ap.add_argument("--model", default="haiku")
ap.add_argument("--budget", default="0.5")
ap.add_argument("extra", nargs="*", help="more claude options, after the --")
args = ap.parse_args()

cmd = ["claude", "-p",
       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--permission-prompt-tool", "stdio",
       "--model", args.model, "--max-budget-usd", args.budget,
       "--no-session-persistence"]
if args.disable_plugin:
    cmd += ["--settings",
            json.dumps({"enabledPlugins": {p: False for p in args.disable_plugin}})]
cmd += args.extra
print("$", " ".join(cmd), file=sys.stderr)

p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, bufsize=1)

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()

def send_user(text):
    send({"type": "user", "message": {"role": "user", "content": text}})

def control(subtype, **fields):
    send({"type": "control_request", "request_id": str(uuid.uuid4()),
          "request": {"subtype": subtype, **fields}})

def answer_questions(inp):
    """Build the updatedInput of an AskUserQuestion, choosing the first option."""
    answers = {}
    for q in inp.get("questions", []):
        labels = [o["label"] for o in q.get("options", [])]
        if q.get("multiSelect") and len(labels) > 1:
            answers[q["question"]] = args.answer_sep.join(labels[:2])
        elif labels:
            answers[q["question"]] = labels[0]
    return {**inp, "answers": answers}

if args.initialize:
    control("initialize", hooks={})

for text in args.prompt:
    send_user(text)

denied = set()
n = 0
# One result closes one prompt; a recording of several prompts is over
# when the last of them has been answered.
results = 0
with open(args.out, "w") as f:
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            break
        f.write(line)
        f.flush()
        n += 1
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") == "control_request" and o["request"].get("subtype") == "can_use_tool":
            req, rid = o["request"], o["request_id"]
            tool, inp = req.get("tool_name"), req.get("input", {})
            if args.policy == "none":
                resp = {"behavior": "deny", "message": "recording without approval"}
            elif tool == "AskUserQuestion":
                resp = {"behavior": "allow", "updatedInput": answer_questions(inp)}
            elif args.policy == "deny-then-allow" and tool not in denied:
                denied.add(tool)
                resp = {"behavior": "deny", "message": args.deny_message}
            else:
                resp = {"behavior": "allow", "updatedInput": inp}
            print(f"  -> {tool}: {resp['behavior']}", file=sys.stderr)
            send({"type": "control_response",
                  "response": {"subtype": "success", "request_id": rid, "response": resp}})
        if o.get("type") == "result":
            results += 1
            if results >= len(args.prompt):
                break

p.stdin.close()
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
print(f"wrote {args.out} ({n} lines)", file=sys.stderr)
EOF
