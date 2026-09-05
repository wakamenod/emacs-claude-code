#!/usr/bin/env bash
# 実 CLI を叩いて stream-json の全行を fixture として記録する。
# 使い方: scripts/record-fixture.sh <出力ファイル> "<プロンプト>" [追加の claude オプション...]
# can_use_tool には allow を返す（記録用）。実装は計画 §7 フェーズ 0 で完成させる。
set -euo pipefail
out="$1"; prompt="$2"; shift 2
python3 - "$out" "$prompt" "$@" <<'EOF'
import subprocess, json, sys, time
out, prompt, *extra = sys.argv[1:]
cmd = ["claude","-p","--input-format","stream-json","--output-format","stream-json","--verbose",
       "--permission-prompt-tool","stdio","--safe-mode","--model","haiku","--max-budget-usd","0.5",
       "--no-session-persistence", *extra]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
send({"type":"user","message":{"role":"user","content":prompt}})
with open(out,"w") as f:
    deadline = time.time()+180
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line: break
        f.write(line)
        try: o = json.loads(line)
        except Exception: continue
        if o.get("type") == "control_request" and o["request"].get("subtype") == "can_use_tool":
            send({"type":"control_response","response":{"subtype":"success","request_id":o["request_id"],
                  "response":{"behavior":"allow","updatedInput":o["request"]["input"]}}})
        if o.get("type") == "result": break
p.kill()
print("wrote", out)
EOF
