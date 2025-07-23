#!/bin/bash

LOCKFILE="/tmp/nasbackup.lock"
LOGFILE="/Users/ryanhoulihan/Library/Logs/nasbackup.log"
TAG="NASBackup"

# === Logging ===
log() {
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $TAG: $1" >> "$LOGFILE"
    if [[ -t 1 ]]; then
        echo "$TAG: $1"
    fi
}

# === Backup ===
run_backup() {
    shift # Drop "run" from args
    PAIRS=("$@")

    # Load from file if first arg is --list=<file>
    if [[ "${PAIRS[0]}" == --list=* ]]; then
        list_file="${PAIRS[0]#--list=}"
        if [ ! -f "$list_file" ]; then
            log "Source list file not found: $list_file"
            exit 1
        fi
        mapfile -t PAIRS < "$list_file"
    fi

    # Validate pairs
    if [ ${#PAIRS[@]} -eq 0 ]; then
        log "No source:destination pairs provided."
        echo "Usage: $0 run <source:dest> [source:dest ...] or --list=path/to/list.txt"
        exit 1
    fi

    # Prevent multiple instances
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        log "Backup already running (PID $(cat "$LOCKFILE")). Exiting."
        exit 0
    fi

    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT

    log "Starting backup of ${#PAIRS[@]} source:destination pair(s)..."

    for pair in "${PAIRS[@]}"; do
        IFS=: read -r SRC DST <<< "$pair"
        SRC="${SRC%\"}"; SRC="${SRC#\"}"  # Trim quotes
        DST="${DST%\"}"; DST="${DST#\"}"

        if [ ! -e "$SRC" ]; then
            log "Source not found: $SRC. Skipping."
            continue
        fi

        if [ ! -d "$DST" ]; then
            log "Destination not found: $DST. Attempting to create..."
            mkdir -p "$DST" || {
                log "Failed to create destination directory: $DST. Skipping."
                continue
            }
        fi

        log "Backing up: $SRC → $DST"

        if [[ -t 1 ]]; then
            # Interactive: show progress live + log
            rsync -avL --update --progress --exclude='.*' --no-times --no-perms --no-owner --no-group "$SRC" "$DST" 2>&1 | tee -a "$LOGFILE"
        else
            # Non-interactive: log only
            rsync -avL --update --progress --exclude='.*' --no-times --no-perms --no-owner --no-group "$SRC" "$DST" >> "$LOGFILE" 2>&1
        fi
        RSYNC_EXIT=$?

        if [ $RSYNC_EXIT -eq 0 ]; then
            log "Backup of $SRC → $DST completed successfully."
        else
            log "Backup of $SRC → $DST failed with errors (rsync exit code $RSYNC_EXIT)."
        fi
    done

    log "All source:destination pairs processed."
}

# === Show last run(s) ===
show_last_run() {
    COUNT="${1:-1}"
    echo "🔍 Checking last $COUNT $TAG run(s)..."

    if [ -f "$LOGFILE" ]; then
        grep -E "Backup of .* completed successfully|Backup of .* failed with errors" "$LOGFILE" | \
        tail -n "$COUNT" | while read -r line; do
            echo "🕒 $line"
        done
    else
        echo "⚠️  No NASBackup log file found."
    fi
}

# === Show status ===
show_status() {
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        echo "🚨 $TAG is currently running (PID $(cat "$LOCKFILE"))"
    else
        echo "✅ $TAG is idle"
    fi

    if [ -f "$LOGFILE" ]; then
        last_success=$(grep "completed successfully" "$LOGFILE" | tail -n 1)
        last_fail=$(grep "failed with errors" "$LOGFILE" | tail -n 1)

        if [[ -n "$last_success" ]]; then
            echo "✅ Last successful: ${last_success#* }"
        else
            echo "✅ Last successful: Never"
        fi
        if [[ -n "$last_fail" ]]; then
            echo "❌ Last failed:      ${last_fail#* }"
        else
            echo "❌ Last failed:      Never"
        fi
    else
        echo "⚠️  No NASBackup log file found."
    fi
}

# === CLI ===
case "$1" in
    run|"")
        run_backup "$@"
        ;;
    last)
        show_last_run "${2:-1}"
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [run <source:dest> ...|run --list=file|last [count]|status]"
        exit 1
        ;;
esac
