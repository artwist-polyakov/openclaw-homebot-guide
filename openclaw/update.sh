#!/bin/bash
set -euo pipefail

LOG=/var/log/openclaw-update.log
REPO=/opt/openclaw/repo
COMPOSE_FILE=/opt/openclaw/docker-compose.yml

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking for updates..." >> $LOG

cd $REPO

# Fetch latest
git fetch origin main 2>&1 >> $LOG

# Check if there are new commits
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Already up to date." >> $LOG
    exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] New version found: $LOCAL -> $REMOTE" >> $LOG

# Pull changes
git pull origin main 2>&1 >> $LOG

# Rebuild Docker image
docker build -t openclaw:local -f Dockerfile . 2>&1 >> $LOG

# Restart gateway
docker compose -f $COMPOSE_FILE up -d openclaw-gateway 2>&1 >> $LOG

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update complete." >> $LOG
