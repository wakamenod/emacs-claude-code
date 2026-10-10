#!/usr/bin/env bash
# Record the conversations the documentation site's pictures replay.
#
#   scripts/docshots-fixtures.sh [NAME...]
#
# Writes scripts/docshots-fixtures/NAME.jsonl, the stream-json of a real
# session, and NAME.prompt beside it, the prompt it was given: the CLI
# never says a prompt back, and the pictures put it on the turn.  These
# are the site's and nobody else's -- the ERT tests read test/fixtures,
# and nothing here is one of those.  scripts/docshots.sh replays them.
#
# Every one is recorded in /tmp/records, laid out first from
# scripts/docshots-project/records, so that the transcripts and the
# source on screen tell one story: reader.py learns to ignore a trailing
# delimiter, gets tests, a plan for a strict mode, and so on.  Recording
# them all costs about a dollar.
#
# What the CLI would bring of this machine is kept out: no MCP server
# (--strict-mcp-config), no user settings, skills or plugins
# (--setting-sources project,local, and every installed plugin turned
# off), and the home directory is written as ~ in what is kept.  Look at
# a new recording before committing it all the same.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/scripts/docshots-fixtures
source=$root/scripts/docshots-project/records
project=/tmp/records
model=${MODEL:-sonnet}

# macOS `open' is not involved here, but a Claude Code session this is
# started from would still hand its environment to the CLI.
for variable in $(env | sed -n 's/^\(CLAUDE[A-Z_]*\)=.*/\1/p'); do
    unset "$variable"
done

plugins=()
while read -r plugin; do
    [ -n "$plugin" ] && plugins+=(--disable-plugin "$plugin")
done < <(python3 - <<'EOF'
import json, os
try:
    settings = json.load(open(os.path.expanduser("~/.claude/settings.json")))
except OSError:
    settings = {}
print("\n".join(settings.get("enabledPlugins") or {}))
EOF
)

# Lay the project out as it is before the first recording, or, with
# EDITED, as it is once the edit recording has made its change.
reset() {
    rm -rf "$project"
    mkdir -p "$project"
    cp "$source/reader.py" "$project/reader.py"
    if [ "${1:-}" = edited ]; then
        cp "$out/edit.reader.py" "$project/reader.py"
    fi
}

# Take out of a recording what is this machine's rather than the
# session's.  The project is /tmp/records to the pictures, and macOS
# answers /private/tmp/records for it; the home directory is nobody's;
# and the answer to `initialize' carries the account -- its email and
# organization -- which ecc never reads.
scrub() {
    sed -i '' -e "s#/private$project#$project#g" -e "s#$HOME/#~/#g" "$1"
    python3 -c '
import json, sys
path = sys.argv[1]
lines = []
for line in open(path):
    message = json.loads(line)
    if message.get("type") == "control_response":
        message.get("response", {}).get("response", {}).pop("account", None)
        line = json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n"
    lines.append(line)
open(path, "w").writelines(lines)
' "$1"
}

# record NAME POLICY PROMPT [record-fixture options...]; options for the
# CLI itself go in the array `cli'.
#
# The recording is made in a directory of its own and moved into place
# only once it has passed the check below: one that names this machine
# is thrown away, and the fixture it would have replaced is left as it
# was.
cli=()
work=$(mktemp -d -t ecc-docshots-fixtures)
record() {
    local name=$1 policy=$2 prompt=$3
    shift 3
    echo "== $name" >&2
    printf '%s\n' "$prompt" > "$work/$name.prompt"
    (cd "$project" && "$root/scripts/record-fixture.sh" \
        --out "$work/$name.jsonl" --prompt "$prompt" --policy "$policy" \
        --model "$model" --budget 2 ${plugins[@]+"${plugins[@]}"} "$@" \
        -- --strict-mcp-config --setting-sources project,local ${cli[@]+"${cli[@]}"})
    scrub "$work/$name.jsonl"
    # What a tool printed is the machine's -- `ls -l' names the owner of
    # every file -- and the prompts can only make that less likely.
    if grep -qw -e "$USER" -e "$(hostname -s)" -e "$(git config user.email || echo "$USER")" "$work/$name.jsonl"; then
        echo "   $name.jsonl names this machine or its user; take it again" >&2
        rm -f "$work/$name.jsonl" "$work/$name.prompt"
        return 1
    fi
    mv "$work/$name.jsonl" "$work/$name.prompt" "$out/"
}

wanted() {
    [ -z "$names" ] && return 0
    case " $names " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
names="$*"

mkdir -p "$out"
# The project is put back however the run ends, a failed check included.
trap 'reset; rm -rf "$work"' EXIT

if wanted edit; then
    reset
    record edit allow 'parse_line in reader.py should ignore a trailing delimiter: "a,b," should give two fields, not three. Make that change.'
    cp "$project/reader.py" "$out/edit.reader.py"
fi

if wanted write; then
    reset edited
    record write allow 'Write test_reader.py with three short pytest tests for parse_line, one of them for the trailing delimiter. Do not run them.'
fi

if wanted plan; then
    reset edited
    cli=(--permission-mode plan)
    record plan none 'Plan a strict mode for read_records: when a row has the wrong number of fields, raise an error that names the file and the line. Read reader.py yourself rather than starting an agent. Keep the plan short: a title, then four or five numbered steps of one short line each, and no other sections.'
    cli=()
fi

if wanted question; then
    reset edited
    record question question 'I want read_records to handle quoted fields. Before changing anything, use AskUserQuestion to ask me two things at once: whether to switch to the csv module or keep the hand-written parser, and, as a multiple choice, which quote characters to accept. Then say in one or two sentences what you would do, and stop.'
fi

if wanted tasks; then
    reset edited
    # Haiku: the CLI offers TaskCreate, TaskUpdate and TaskList to a
    # haiku session and none of them to a sonnet one (2.1.290,
    # 2026-10-10), and a sonnet session searched for them and gave up.
    model=haiku
    record tasks allow 'Use the task tools: add two tasks, "Support quoted fields" and "Document the delimiter option", start the first and mark it done. Do not edit any files.'
    model=${MODEL:-sonnet}
fi

if wanted basic; then
    reset edited
    record basic allow 'In one line, what does reader.py do?' --initialize
fi

if wanted deny; then
    reset edited
    record deny deny-then-allow 'Write cli.py, a small argparse script that prints the records of a file named on the command line, one per line, tab-separated. reader.py has read_records. Do not run it.' \
        --deny-message 'Not yet: I want it named records_cli.py, and with a -d option for the delimiter. Please write that instead.'
fi

if wanted background; then
    reset edited
    record background allow 'Start python3 -m http.server 8000 in the background so I can browse the files. Reply with the URL only.'
    # The server outlives the recording; it was only there to be started.
    pkill -f '^[^ ]*[Pp]ython[0-9.]* -m http.server 8000$' 2>/dev/null || true
fi

echo "recorded ${names:-every fixture} into $out" >&2
