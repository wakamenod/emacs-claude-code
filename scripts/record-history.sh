#!/usr/bin/env bash
# 実 CLI に数ターン会話させ、~/.claude/projects に残る jsonl を fixture として
# 取り込む（フェーズ 5 / FR-HIST-1〜3 のリプレイテスト用）。
#
#   scripts/record-history.sh --out test/fixtures/history-session.jsonl \
#       --prompt "hello" --prompt "hi.txt を作って"
#
# record-fixture.sh と違い --no-session-persistence を付けない。履歴ファイルが
# 書かれないと意味が無いため。作業ディレクトリは毎回作り直す一時ディレクトリで、
# 記録後に消す。開発ルール（CLAUDE.md）どおり --model haiku と --max-budget-usd
# を必ず付け、emacs-gravity の hooks を --settings で止める。
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
ap.add_argument("--keep-cwd", action="store_true", help="作業ディレクトリを消さない")
args = ap.parse_args()

session_id = str(uuid.uuid4())
cwd = tempfile.mkdtemp(prefix="ecc-history-")
projects = pathlib.Path.home() / ".claude" / "projects"
# ディレクトリ名は cwd（シンボリックリンク解決済み）の英数字とハイフン以外を
# すべて - に置き換えたもの（docs/verified.md）。
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
        sys.exit(f"履歴ファイルが見つからない: {src}")
    src = hits[0]
os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
shutil.copyfile(src, args.out)
lines = sum(1 for _ in open(args.out))
print(f"wrote {args.out} ({lines} lines) from {src}", file=sys.stderr)
if not args.keep_cwd:
    shutil.rmtree(cwd, ignore_errors=True)
EOF
