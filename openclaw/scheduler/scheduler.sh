#!/usr/bin/env bash
# scheduler.sh — CLI for managing OpenClaw scheduler tasks.
# Deployed to each agent's workspace as a skill tool.
#
# Usage:
#   scheduler.sh list
#   scheduler.sh add --name "..." --cron "0 9 * * *" --prompt "..."
#                     [--agent <id>] [--channel telegram] [--to "<chat-id>"] [--max-runs N]
#   scheduler.sh add --name "..." --every 3600 --prompt "..."
#   scheduler.sh add --name "..." --at "2026-03-01T10:00" --prompt "..."
#   scheduler.sh remove --id <task-id>
#   scheduler.sh enable --id <task-id>
#   scheduler.sh disable --id <task-id>
#   scheduler.sh status
#
# Environment:
#   SCHEDULER_TASKS_DIR  — path to tasks directory (default: /opt/openclaw/config/scheduler)
#   SCHEDULER_AGENT_ID   — default agent ID for this workspace (default: main)

set -euo pipefail

TASKS_DIR="${SCHEDULER_TASKS_DIR:-/opt/openclaw/config/scheduler}"
AGENT_ID="${SCHEDULER_AGENT_ID:-main}"
TASKS_FILE="${TASKS_DIR}/tasks-${AGENT_ID}.json"

ensure_tasks_file() {
    if [ ! -f "$TASKS_FILE" ]; then
        mkdir -p "$TASKS_DIR"
        echo '{"version": 1, "tasks": []}' > "$TASKS_FILE"
    fi
}

cmd_list() {
    ensure_tasks_file
    python3 -c "
import json, sys
with open('$TASKS_FILE') as f:
    data = json.load(f)
tasks = data.get('tasks', [])
if not tasks:
    print('No tasks.')
    sys.exit(0)
print(f'Tasks ({len(tasks)}):')
print()
for t in tasks:
    status = 'ON' if t.get('enabled', True) else 'OFF'
    sched = t.get('schedule', {})
    kind = sched.get('kind', '?')
    if kind == 'cron':
        sched_str = f'cron: {sched.get(\"expr\", \"?\")}'
    elif kind == 'every':
        sched_str = f'every {sched.get(\"everySeconds\", 0)}s'
    elif kind == 'at':
        sched_str = f'at: {sched.get(\"at\", \"?\")}'
    else:
        sched_str = '?'
    runs = t.get('runCount', 0)
    last = t.get('lastRunAt', 'never')
    agent = t.get('agentId', '-')
    print(f'  [{status}] {t.get(\"id\", \"?\")} | {t.get(\"name\", \"?\")}')
    print(f'        schedule: {sched_str} | runs: {runs} | last: {last} | agent: {agent}')
    print()
"
}

cmd_add() {
    local name="" prompt="" cron_expr="" every="" at="" agent="$AGENT_ID" channel="" to="" max_runs=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     name="$2";      shift 2 ;;
            --prompt)   prompt="$2";    shift 2 ;;
            --cron)     cron_expr="$2"; shift 2 ;;
            --every)    every="$2";     shift 2 ;;
            --at)       at="$2";        shift 2 ;;
            --agent)    agent="$2";     shift 2 ;;
            --channel)  channel="$2";   shift 2 ;;
            --to)       to="$2";        shift 2 ;;
            --max-runs) max_runs="$2";  shift 2 ;;
            *)          echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    if [ -z "$name" ] || [ -z "$prompt" ]; then
        echo "Error: --name and --prompt are required"
        exit 1
    fi

    if [ -z "$cron_expr" ] && [ -z "$every" ] && [ -z "$at" ]; then
        echo "Error: one of --cron, --every, or --at is required"
        exit 1
    fi

    ensure_tasks_file

    python3 -c "
import json, hashlib, time

with open('$TASKS_FILE') as f:
    data = json.load(f)

task_id = hashlib.md5(('$name' + str(time.time())).encode()).hexdigest()[:8]

schedule = {}
if '$cron_expr':
    schedule = {'kind': 'cron', 'expr': '$cron_expr'}
elif '$every':
    schedule = {'kind': 'every', 'everySeconds': int('$every')}
elif '$at':
    schedule = {'kind': 'at', 'at': '$at'}

task = {
    'id': task_id,
    'name': '$name',
    'prompt': $(python3 -c "import json; print(json.dumps('$prompt'))"),
    'schedule': schedule,
    'enabled': True,
    'runCount': 0,
    'lastRunAt': None,
    'agentId': '$agent' or None,
    'channel': '$channel' or None,
    'to': '$to' or None,
}
max_runs = '$max_runs'
if max_runs:
    task['maxRuns'] = int(max_runs)

data.setdefault('tasks', []).append(task)

with open('$TASKS_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print(f'Added task {task_id}: {task[\"name\"]}')
"
}

cmd_remove() {
    local task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) task_id="$2"; shift 2 ;;
            *)    echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    if [ -z "$task_id" ]; then
        echo "Error: --id is required"
        exit 1
    fi

    ensure_tasks_file

    python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
before = len(data.get('tasks', []))
data['tasks'] = [t for t in data.get('tasks', []) if t.get('id') != '$task_id']
after = len(data['tasks'])
if before == after:
    print(f'Task $task_id not found')
else:
    with open('$TASKS_FILE', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f'Removed task $task_id')
"
}

cmd_toggle() {
    local task_id="" enabled="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) task_id="$2"; shift 2 ;;
            *)    echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    if [ -z "$task_id" ]; then
        echo "Error: --id is required"
        exit 1
    fi

    ensure_tasks_file

    python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
found = False
for t in data.get('tasks', []):
    if t.get('id') == '$task_id':
        t['enabled'] = $enabled
        found = True
        break
if not found:
    print(f'Task $task_id not found')
else:
    with open('$TASKS_FILE', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    state = 'enabled' if $enabled else 'disabled'
    print(f'Task $task_id {state}')
"
}

cmd_status() {
    ensure_tasks_file

    local count
    count=$(python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
tasks = data.get('tasks', [])
enabled = sum(1 for t in tasks if t.get('enabled', True))
print(f'{enabled} enabled / {len(tasks)} total')
")

    echo "Agent: $AGENT_ID"
    echo "Tasks file: $TASKS_FILE"
    echo "Tasks: $count"

    if command -v systemctl &>/dev/null; then
        local daemon_status
        daemon_status=$(systemctl is-active scheduler-daemon 2>/dev/null || echo "unknown")
        echo "Daemon: $daemon_status"
    fi
}

# --- Main ---
case "${1:-}" in
    list)    cmd_list ;;
    add)     shift; cmd_add "$@" ;;
    remove)  shift; cmd_remove "$@" ;;
    enable)  shift; cmd_toggle "True" "$@" ;;
    disable) shift; cmd_toggle "False" "$@" ;;
    status)  cmd_status ;;
    *)
        echo "Usage: scheduler.sh {list|add|remove|enable|disable|status}"
        echo ""
        echo "Examples:"
        echo "  scheduler.sh list"
        echo "  scheduler.sh add --name 'Morning check' --cron '0 9 * * *' --prompt 'Check tasks'"
        echo "  scheduler.sh add --name 'Hourly ping' --every 3600 --prompt 'Ping'"
        echo "  scheduler.sh remove --id a1b2c3d4"
        echo "  scheduler.sh enable --id a1b2c3d4"
        echo "  scheduler.sh disable --id a1b2c3d4"
        echo "  scheduler.sh status"
        exit 1
        ;;
esac
