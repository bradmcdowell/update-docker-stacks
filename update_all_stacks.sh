#!/bin/bash

# Resolve the absolute directory where this script resides to ensure relative paths work in cron
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/stack_updates.log"
GITIGNORE_FILE="${SCRIPT_DIR}/.gitignore"

# Ensure the logs directory exists
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== Starting Active Stack Updates: $(date) ===" >> "$LOG_FILE"

# Get working directory of every running compose project
docker compose ls --format json | grep -o '"ConfigFiles":"[^"]*"' | cut -d'"' -f4 | while read -r config_path; do
    # Extract directory from config path (handles multi-config CSV formats)
    first_config=$(echo "$config_path" | cut -d',' -f1)
    stack_dir=$(dirname "$first_config")

    if [ -d "$stack_dir" ]; then
        echo "Processing active stack in: $stack_dir" >> "$LOG_FILE"
        (
            cd "$stack_dir" || exit
            docker compose pull && docker compose up -d
        ) >> "$LOG_FILE" 2>&1
    fi
done

echo "Cleaning up unused images..." >> "$LOG_FILE"
docker image prune -f >> "$LOG_FILE" 2>&1

echo "=== Completed Stack Updates: $(date) ===" >> "$LOG_FILE"
