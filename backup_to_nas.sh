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

# === Show last run status ===
show_last_run_status() {
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        echo "🔄 CURRENTLY BACKING UP!"
        current_file=$(lsof -p $(cat "$LOCKFILE") | grep "/Users/ryanhoulihan" | awk '{print $NF}' | tail -n 1)
        if [[ -n "$current_file" ]]; then
            echo "➡️  Current File: $current_file"
        else
            echo "➡️  Current file information unavailable."
        fi
    elif [ -n "$last_fail" ]; then
        echo "⚠️  LAST RUN FAILED"
        echo "   Last Issue: $fail_time"
        echo "   File/Folder: $fail_path"
        echo "   Exit Code: $exit_code (Note: May indicate partial sync, not complete failure)"
        echo "➡️  Last File Attempted: $fail_path"
    elif [ -n "$last_success" ]; then
        echo "✅ LAST RUN SUCCESSFUL"
        echo "➡️  Last File: $success_path"
    else
        echo "❔ LAST RUN INFORMATION UNAVAILABLE"
    fi
}

# === Show status ===
show_status() {
    echo "📊 $TAG Status Report"
    echo "==========================================="
    
    # Current running status
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        echo "🔄 Current Status: RUNNING (PID $(cat "$LOCKFILE"))"
    else
        echo "✅ Current Status: IDLE"
    fi
    
    # Check mount status
    echo ""
    echo "💾 Mount Status:"
    if mount | grep -q "/Users/ryanhoulihan/Library/Volumes/NAS"; then
        echo "✅ NAS is mounted at /Users/ryanhoulihan/Library/Volumes/NAS"
    elif [ -d "/Volumes/home" ] && mount | grep -q "/Volumes/home"; then
        echo "✅ NAS is mounted at /Volumes/home"
    else
        echo "❌ NAS is not mounted"
    fi
    
    echo ""
    if [ -f "$LOGFILE" ]; then
        # Get last backup activity
        last_start=$(grep "Starting backup" "$LOGFILE" | tail -n 1)
        last_success=$(grep "completed successfully" "$LOGFILE" | tail -n 1)
        last_fail=$(grep "failed with errors" "$LOGFILE" | tail -n 1)
        
        # Show last backup attempt
        if [[ -n "$last_start" ]]; then
            start_time=$(echo "$last_start" | awk '{print $1, $2}')
            echo "🕐 Last Backup Attempt: $start_time"
        fi
        
        # Parse data for last run status function
        if [[ -n "$last_success" ]]; then
            success_time=$(echo "$last_success" | awk '{print $1, $2}')
            success_path=$(echo "$last_success" | grep -o 'Backup of [^→]*' | sed 's/Backup of //')
        fi
        if [[ -n "$last_fail" ]]; then
            fail_time=$(echo "$last_fail" | awk '{print $1, $2}')
            fail_path=$(echo "$last_fail" | grep -o 'Backup of [^→]*' | sed 's/Backup of //')
            exit_code=$(echo "$last_fail" | grep -o 'exit code [0-9]*' | grep -o '[0-9]*')
        fi
        
        # Show last run status
        echo ""
        echo "📋 Last Run Status:"
        show_last_run_status
        
        
    else
        echo "⚠️  No backup log file found at: $LOGFILE"
    fi
    
    echo "==========================================="
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
