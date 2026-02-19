#!/usr/bin/env python3
"""
Scheduler daemon — reads per-agent task files and triggers OpenClaw hooks API on schedule.

Scans SCHEDULER_TASKS_DIR for tasks-{agentId}.json files every 30 seconds.
For due tasks, sends POST /hooks/agent.
Supports: cron expressions (basic parser), "every" intervals, one-shot "at" timestamps.

Environment variables:
  SCHEDULER_TASKS_DIR   — path to directory with tasks-*.json files (default: /opt/openclaw/config/scheduler)
  SCHEDULER_GATEWAY     — OpenClaw gateway URL (default: http://127.0.0.1:18789)
  SCHEDULER_HOOKS_TOKEN — bearer token for hooks API (required)
  SCHEDULER_HOOKS_PATH  — hooks API path prefix (default: /hooks)
"""

import json
import time
import os
import sys
import logging
import glob
from datetime import datetime, timezone, timedelta
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from pathlib import Path

TASKS_DIR = os.environ.get("SCHEDULER_TASKS_DIR", "/opt/openclaw/config/scheduler")
GATEWAY_URL = os.environ.get("SCHEDULER_GATEWAY", "http://127.0.0.1:18789")
HOOKS_TOKEN = os.environ.get("SCHEDULER_HOOKS_TOKEN", "")
HOOKS_PATH = os.environ.get("SCHEDULER_HOOKS_PATH", "/hooks")
CHECK_INTERVAL = 30  # seconds
TZ_OFFSET = timedelta(hours=3)  # MSK
MSK = timezone(TZ_OFFSET)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [scheduler] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("scheduler")


def now_msk():
    return datetime.now(MSK)


def find_task_files():
    """Find all tasks-*.json files in the tasks directory."""
    pattern = os.path.join(TASKS_DIR, "tasks-*.json")
    return sorted(glob.glob(pattern))


def load_tasks_from_file(file_path):
    try:
        with open(file_path, "r") as f:
            data = json.load(f)
        return data.get("tasks", [])
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.error(f"Failed to load {file_path}: {e}")
        return []


def save_tasks_to_file(file_path, tasks):
    Path(file_path).parent.mkdir(parents=True, exist_ok=True)
    data = {"version": 1, "tasks": tasks}
    tmp = file_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, file_path)


def parse_cron_field(field, min_val, max_val):
    """Parse a single cron field into a set of valid values."""
    values = set()
    for part in field.split(","):
        part = part.strip()
        if part == "*":
            values.update(range(min_val, max_val + 1))
        elif "/" in part:
            base, step = part.split("/", 1)
            step = int(step)
            start = min_val if base == "*" else int(base)
            values.update(range(start, max_val + 1, step))
        elif "-" in part:
            a, b = part.split("-", 1)
            values.update(range(int(a), int(b) + 1))
        else:
            values.add(int(part))
    return values


def cron_matches(expr, dt):
    """Check if datetime matches a cron expression (min hour dom month dow)."""
    parts = expr.strip().split()
    if len(parts) != 5:
        return False
    minutes = parse_cron_field(parts[0], 0, 59)
    hours = parse_cron_field(parts[1], 0, 23)
    doms = parse_cron_field(parts[2], 1, 31)
    months = parse_cron_field(parts[3], 1, 12)
    dows = parse_cron_field(parts[4], 0, 6)  # 0=Sunday

    py_dow = (dt.weekday() + 1) % 7  # Python: 0=Mon -> cron: 0=Sun
    return (
        dt.minute in minutes
        and dt.hour in hours
        and dt.day in doms
        and dt.month in months
        and py_dow in dows
    )


def is_task_due(task, dt):
    """Check if a task should run at the given datetime."""
    if not task.get("enabled", True):
        return False

    schedule = task.get("schedule", {})
    kind = schedule.get("kind")

    if kind == "cron":
        return cron_matches(schedule.get("expr", ""), dt)

    elif kind == "every":
        every_sec = schedule.get("everySeconds", 0)
        if every_sec <= 0:
            return False
        last_run = task.get("lastRunAt")
        if not last_run:
            return True
        last_dt = datetime.fromisoformat(last_run)
        return (dt - last_dt).total_seconds() >= every_sec

    elif kind == "at":
        at_str = schedule.get("at", "")
        if not at_str:
            return False
        at_dt = datetime.fromisoformat(at_str)
        if at_dt.tzinfo is None:
            at_dt = at_dt.replace(tzinfo=MSK)
        if task.get("lastRunAt"):
            return False
        return dt >= at_dt

    return False


def trigger_task(task):
    """Send task to OpenClaw via hooks/agent API."""
    payload = {
        "message": task.get("prompt", ""),
        "name": f"Scheduled: {task.get('name', 'task')}",
        "wakeMode": "now",
        "deliver": True,
    }
    for field in ("agentId", "channel", "to", "timeoutSeconds"):
        if task.get(field):
            payload[field] = task[field]

    url = f"{GATEWAY_URL}{HOOKS_PATH}/agent"
    body = json.dumps(payload).encode()
    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {HOOKS_TOKEN}")

    try:
        resp = urlopen(req, timeout=30)
        result = json.loads(resp.read().decode())
        log.info(f"Triggered '{task.get('name')}': {result}")
        return True
    except (HTTPError, URLError) as e:
        log.error(f"Failed to trigger '{task.get('name')}': {e}")
        return False


def run_loop():
    log.info(f"Scheduler daemon started (tasks dir: {TASKS_DIR})")
    log.info(f"Gateway: {GATEWAY_URL}, check interval: {CHECK_INTERVAL}s")

    last_check_minute = None

    while True:
        try:
            dt = now_msk()
            current_minute = dt.strftime("%Y-%m-%d %H:%M")

            # Only check once per minute for cron tasks (avoid double-firing)
            if current_minute == last_check_minute:
                time.sleep(CHECK_INTERVAL)
                continue
            last_check_minute = current_minute

            task_files = find_task_files()
            if not task_files:
                time.sleep(CHECK_INTERVAL)
                continue

            for file_path in task_files:
                tasks = load_tasks_from_file(file_path)
                if not tasks:
                    continue

                modified = False
                for task in tasks:
                    if is_task_due(task, dt):
                        log.info(
                            f"Task due: {task.get('name')} [{task.get('id')}] "
                            f"from {os.path.basename(file_path)}"
                        )
                        success = trigger_task(task)
                        if success:
                            task["lastRunAt"] = dt.isoformat()
                            task["runCount"] = task.get("runCount", 0) + 1
                            modified = True

                            if task.get("schedule", {}).get("kind") == "at":
                                task["enabled"] = False
                                log.info(f"One-shot task '{task.get('name')}' completed, disabled")

                            max_runs = task.get("maxRuns")
                            if max_runs and task["runCount"] >= max_runs:
                                task["enabled"] = False
                                log.info(
                                    f"Task '{task.get('name')}' reached maxRuns={max_runs}, disabled"
                                )

                if modified:
                    save_tasks_to_file(file_path, tasks)

        except Exception as e:
            log.error(f"Loop error: {e}")

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    if not HOOKS_TOKEN:
        log.error("SCHEDULER_HOOKS_TOKEN not set")
        sys.exit(1)
    run_loop()
