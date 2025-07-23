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

# === Get last synced file from rsync output ===
get_last_synced_file() {
    # Look for the last file that was actually transferred (not just listed)
    # Find lines that show file transfers in rsync output
    last_transferred_file=$(grep -E '^[^/]+\.(jpg|jpeg|png|gif|mov|mp4|avi|mkv|pdf|doc|docx|txt|md|sh|py|js|html|css|json|xml|zip|tar|gz|dmg|pkg|app|heic|cr2|raw|tiff|psd)$' "$LOGFILE" | tail -1 2>/dev/null)
    
    if [[ -z "$last_transferred_file" ]]; then
        # Fallback: look for any file-like pattern in recent log entries
        last_transferred_file=$(tail -100 "$LOGFILE" | grep -E '\.(jpg|jpeg|png|gif|mov|mp4|avi|mkv|pdf|doc|docx|txt|md|sh|py|js|html|css|json|xml|zip|tar|gz|dmg|pkg|app|heic|cr2|raw|tiff|psd)$' | tail -1 2>/dev/null)
    fi
    
    echo "$last_transferred_file"
}

# === Show status ===
show_status() {
    # Check mount status
    if mount | grep -q "/Users/ryanhoulihan/Library/Volumes/NAS"; then
        mount_msg="✅ /Users/ryanhoulihan/Library/Volumes/NAS"
    elif [ -d "/Volumes/home" ] && mount | grep -q "/Volumes/home"; then
        mount_msg="✅ /Volumes/home"
    else
        mount_msg="❌ Not mounted"
    fi
    
    # Current running status
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        current_status="🔄 Running"
    else
        current_status="✅ Idle"
    fi
    
    echo "Mounted: $mount_msg"
    echo "Current Status: $current_status"
    echo ""
    
    if [ -f "$LOGFILE" ]; then
        # Get last backup activity
        last_start=$(grep "Starting backup" "$LOGFILE" | tail -n 1)
        last_success=$(grep "completed successfully" "$LOGFILE" | tail -n 1)
        last_fail=$(grep "failed with errors" "$LOGFILE" | tail -n 1)
        
        # Determine last run time and status
        if [[ -n "$last_start" ]]; then
            last_run_time=$(echo "$last_start" | awk '{print $1, $2}')
        else
            last_run_time="Never"
        fi
        
        # Determine last run status
        if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
            last_run_status="🔄 Currently running"
        elif [[ -n "$last_success" ]] && [[ -n "$last_fail" ]]; then
            # Compare timestamps to see which is more recent
            success_time=$(echo "$last_success" | awk '{print $1, $2}')
            fail_time=$(echo "$last_fail" | awk '{print $1, $2}')
            if [[ "$success_time" > "$fail_time" ]]; then
                last_run_status="✅ Success"
            else
                exit_code=$(echo "$last_fail" | grep -o 'exit code [0-9]*' | grep -o '[0-9]*')
                last_run_status="⚠️ Failed (exit code $exit_code)"
            fi
        elif [[ -n "$last_success" ]]; then
            last_run_status="✅ Success"
        elif [[ -n "$last_fail" ]]; then
            exit_code=$(echo "$last_fail" | grep -o 'exit code [0-9]*' | grep -o '[0-9]*')
            last_run_status="⚠️ Failed (exit code $exit_code)"
        else
            last_run_status="❔ Unknown"
        fi
        
        # Get last synced file
        last_synced_file=$(get_last_synced_file)
        if [[ -z "$last_synced_file" ]]; then
            last_synced_file="None found"
        fi
        
        echo "Last Run: $last_run_time"
        echo "Last Run Status: $last_run_status"
        echo "Last synced file: $last_synced_file"
        
    else
        echo "Last Run: Never"
        echo "Last Run Status: ❔ No log file"
        echo "Last synced file: None found"
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
