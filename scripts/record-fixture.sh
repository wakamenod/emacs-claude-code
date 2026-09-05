#!/usr/bin/env bash
# 実 CLI を叩いて stream-json の全行を fixture として記録する。
#
#   scripts/record-fixture.sh --out test/fixtures/basic-turn.jsonl \
#       --prompt "hello" [--policy allow] [-- 追加の claude オプション...]
#
# stdout の全行をそのまま OUT に書く。制御要求（can_use_tool）には --policy に
# 従って応答する。開発ルール（CLAUDE.md）どおり --model haiku と
# --max-budget-usd を必ず付け、emacs-gravity の hooks を --settings で止める。
set -euo pipefail
exec python3 - "$@" <<'EOF'
import argparse, json, subprocess, sys, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--prompt", action="append", required=True,
                help="送るプロンプト。複数指定すると連続で送る")
ap.add_argument("--policy", default="allow",
                choices=["allow", "deny-then-allow", "question", "plan", "none"])
ap.add_argument("--deny-message", default="内容を hi にして")
ap.add_argument("--answer-sep", default=", ",
                help="AskUserQuestion の multiSelect 回答の区切り")
ap.add_argument("--initialize", action="store_true", help="先に initialize を送る")
ap.add_argument("--timeout", type=float, default=300.0)
ap.add_argument("--disable-plugin", action="append",
                default=["emacs-bridge@emacs-gravity-marketplace"],
                help="このセッションだけ止めるプラグイン。--safe-mode と違い "
                     "MCP・skills・コマンドは残る（docs/verified.md の D2）")
ap.add_argument("--model", default="haiku")
ap.add_argument("--budget", default="0.5")
ap.add_argument("extra", nargs="*", help="追加の claude オプション（-- の後ろ）")
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
    """AskUserQuestion の updatedInput を作る。先頭の選択肢を選ぶ。"""
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
            break

p.stdin.close()
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill()
print(f"wrote {args.out} ({n} lines)", file=sys.stderr)
EOF
