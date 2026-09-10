#!/usr/bin/env bash
# Let the real CLI talk for a few turns and take the jsonl it leaves in
# ~/.claude/projects as a fixture (for the replay tests of phase 5 /
# FR-HIST-1..3).
#
#   scripts/record-history.sh --out test/fixtures/history-session.jsonl \
#       --prompt "hello" --prompt "hi.txt を作って"
#
# Unlike record-fixture.sh this does not pass --no-session-persistence:
# without the history file there is nothing to record.  The working
# directory is a fresh temporary one, removed after the recording.  As the
# development rules (CLAUDE.md) require, --model haiku and --max-budget-usd
# are always passed, and the emacs-gravity hooks are turned off with
# --settings.
set -euo pipefail
exec python3 - "$@" <<'EOF'
import argparse, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--prompt", action="append", required=True)
ap.add_argument("--timeout", type=float, default=300.0)
ap.add_argument("--disable-plugin", action="append",
                default=["emacs-bridge@emacs-gravity-marketplace"])
ap.add_argument("--model", default="haiku")
ap.add_argument("--budget", default="0.5")
ap.add_argument("--keep-cwd", action="store_true", help="keep the working directory")
args = ap.parse_args()

session_id = str(uuid.uuid4())
cwd = tempfile.mkdtemp(prefix="ecc-history-")
projects = pathlib.Path.home() / ".claude" / "projects"
# The directory name is the cwd (with symlinks resolved) with everything
# but letters, digits and hyphens replaced by - (confirmed against the CLI).
cwd = os.path.realpath(cwd)
encoded = re.sub(r"[^A-Za-z0-9-]", "-", cwd.rstrip("/"))

cmd = ["claude", "-p",
       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--permission-prompt-tool", "stdio",
       "--session-id", session_id,
       "--model", args.model, "--max-budget-usd", args.budget]
if args.disable_plugin:
    cmd += ["--settings",
            json.dumps({"enabledPlugins": {p: False for p in args.disable_plugin}})]
print("$ cd", cwd, "&&", " ".join(cmd), file=sys.stderr)

p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, bufsize=1, cwd=cwd)

def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()

prompts = list(args.prompt)
send({"type": "user", "message": {"role": "user", "content": prompts.pop(0)}})

deadline = time.time() + args.timeout
while time.time() < deadline:
    line = p.stdout.readline()
    if not line:
        break
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") == "control_request" and o["request"].get("subtype") == "can_use_tool":
        req, rid = o["request"], o["request_id"]
        print(f"  -> {req.get('tool_name')}: allow", file=sys.stderr)
        send({"type": "control_response",
              "response": {"subtype": "success", "request_id": rid,
                           "response": {"behavior": "allow",
                                        "updatedInput": req.get("input", {})}}})
    if o.get("type") == "result":
        print(f"  turn done ({o.get('subtype')})", file=sys.stderr)
        if not prompts:
            break
        send({"type": "user", "message": {"role": "user", "content": prompts.pop(0)}})

p.stdin.close()
try:
    p.wait(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()

src = projects / encoded / f"{session_id}.jsonl"
if not src.exists():
    hits = list(projects.glob(f"*/{session_id}.jsonl"))
    if not hits:
        sys.exit(f"history file not found: {src}")
    src = hits[0]
os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
shutil.copyfile(src, args.out)
lines = sum(1 for _ in open(args.out))
print(f"wrote {args.out} ({lines} lines) from {src}", file=sys.stderr)
if not args.keep_cwd:
    shutil.rmtree(cwd, ignore_errors=True)
EOF
