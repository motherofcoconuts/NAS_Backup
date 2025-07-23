#!/bin/bash

LOCKFILE="/tmp/nasbackup.lock"
LOGFILE="/Users/ryanhoulihan/Library/Logs/nasbackup.log"
JOB_STATUS_FILE="/Users/ryanhoulihan/Library/Logs/nasbackup_job_status.log"
TAG="NASBackup"

# === Logging ===
log() {
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $TAG: $1" >> "$LOGFILE"
    if [[ -t 1 ]]; then
        echo "$TAG: $1"
    fi
}

# === Thread-safe counters ===
total_files=0
synced_files=0

increment_total_files() {
    ((total_files++))
}

increment_synced_files() {
    ((synced_files++))
}

# === Real-time progress tracking ===
update_progress_checkpoint() {
    local current_synced="$1"
    local job_id="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write progress checkpoint to a separate file for real-time tracking
    echo "PROGRESS|$job_id|$timestamp|$current_synced|$total_files" > "${JOB_STATUS_FILE}.progress"
    
    # Also log to main log for visibility
    log "Progress checkpoint: $current_synced/$total_files files synced (Job ID: $job_id)"
}

# Function to get current synced count from rsync progress
get_current_synced_count() {
    local logfile="$1"
    local base_count="$2"  # Files already synced from previous pairs
    
    # Look for rsync transfer count from progress output
    # Format: "   123456789 100%    5.08MB/s    0:02:37 (xfer#10, to-check=34412/35182)"
    local xfer_count=$(grep 'xfer#' "$logfile" | tail -n 1 | grep -o 'xfer#[0-9]*' | cut -d'#' -f2)
    
    if [[ -n "$xfer_count" && "$xfer_count" =~ ^[0-9]+$ ]]; then
        echo $((base_count + xfer_count))
    else
        echo "$base_count"
    fi
}

# === Job Run Tracking ===
log_job_start() {
    local job_id="$(date '+%Y%m%d_%H%M%S')_$$"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "JOB_START|$job_id|$timestamp|${#PAIRS[@]}" >> "$JOB_STATUS_FILE"
    echo "$job_id"
}

log_job_end() {
    local job_id="$1"
    local status="$2"  # SUCCESS or FAILED
    local unsynced_files="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Use durable write pattern for consistency
    local temp_status_file="${JOB_STATUS_FILE}.tmp.$$"
    
    # Write to temporary file first, then atomically move
    {
        if [[ -f "$JOB_STATUS_FILE" ]]; then
            cat "$JOB_STATUS_FILE"
        fi
        echo "JOB_END|$job_id|$timestamp|$status|$unsynced_files"
    } > "$temp_status_file"
    
    # Atomically move temp file to final location
    if mv "$temp_status_file" "$JOB_STATUS_FILE" 2>/dev/null; then
        # Force filesystem sync to ensure data is written to disk
        sync
    else
        # Fallback: direct write if atomic move failed
        echo "JOB_END|$job_id|$timestamp|$status|$unsynced_files" >> "$JOB_STATUS_FILE"
        sync
    fi
    
    # Clean up temp file if it still exists
    rm -f "$temp_status_file" 2>/dev/null || true
}

get_total_files_to_sync() {
    local src="$1"
    local dst="$2"
    # Use rsync dry-run to count files that would be transferred
    # Count all files that rsync would transfer (not just specific extensions)
    local count=$(rsync -avL --update --dry-run --exclude='.*' --no-times --no-perms --no-owner --no-group "$src" "$dst" 2>/dev/null | \
    grep -v '^building file list' | \
    grep -v '^sent ' | \
    grep -v '^total size' | \
    grep -v '^$' | \
    grep -v '^\.$' | \
    grep -v '/$' | \
    wc -l | tr -d ' ')
    echo "$count"
}

get_unsynced_files_count() {
    # Extract the most recent "to-check" count from rsync progress output
    local files_left=$(grep 'to-check=' "$LOGFILE" | tail -n 1 | grep -o 'to-check=[0-9]*/[0-9]*' | cut -d'=' -f2 | cut -d'/' -f1)
    if [[ -z "$files_left" ]]; then
        echo "0"
    else
        echo "$files_left"
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
    
    # Enhanced exception/interrupt handler with durable writes
    cleanup_and_exit() {
        local exit_code=$?
        local signal_name="${1:-UNKNOWN}"
        
        log "Signal/exception handler triggered: $signal_name (exit code: $exit_code)"
        
        if [[ -n "$JOB_ID" ]]; then
            # Calculate unsynced files
            unsynced_files=$((total_files - synced_files))
            
            # Ensure durable write with transaction-like behavior
            local temp_status_file="${JOB_STATUS_FILE}.tmp.$$"
            local backup_status_file="${JOB_STATUS_FILE}.backup.$$"
            
            # Create backup of current status file
            if [[ -f "$JOB_STATUS_FILE" ]]; then
                cp "$JOB_STATUS_FILE" "$backup_status_file" 2>/dev/null || true
            fi
            
            # Write to temporary file first (atomic operation)
            {
                if [[ -f "$JOB_STATUS_FILE" ]]; then
                    cat "$JOB_STATUS_FILE"
                fi
                local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
                echo "JOB_END|$JOB_ID|$timestamp|INTERRUPTED_$signal_name|$unsynced_files"
            } > "$temp_status_file"
            
            # Atomically move temp file to final location (ensures durability)
            if mv "$temp_status_file" "$JOB_STATUS_FILE" 2>/dev/null; then
                # Force filesystem sync to ensure data is written to disk
                sync
                
                # Verify the write was successful
                if grep -q "JOB_END|$JOB_ID" "$JOB_STATUS_FILE" 2>/dev/null; then
                    log "Successfully persisted unsynced count: $unsynced_files (Signal: $signal_name, Job ID: $JOB_ID)"
                    # Clean up backup file on successful write
                    rm -f "$backup_status_file" 2>/dev/null || true
                else
                    log "ERROR: Failed to verify job status write, attempting recovery"
                    # Restore from backup if verification failed
                    if [[ -f "$backup_status_file" ]]; then
                        mv "$backup_status_file" "$JOB_STATUS_FILE" 2>/dev/null || true
                    fi
                fi
            else
                log "ERROR: Failed to write job status atomically, attempting direct write"
                # Fallback: direct write if atomic move failed
                local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
                echo "JOB_END|$JOB_ID|$timestamp|INTERRUPTED_$signal_name|$unsynced_files" >> "$JOB_STATUS_FILE"
                sync
            fi
            
            # Also write to main log with flush
            log "Backup job interrupted by $signal_name. Unsynced files: $unsynced_files (Job ID: $JOB_ID)"
            # Force log flush to disk
            sync
            
            # Clean up any remaining temp files
            rm -f "$temp_status_file" "$backup_status_file" 2>/dev/null || true
        fi
        
        # Clean up lock file
        rm -f "$LOCKFILE"
        
        # Exit with appropriate code
        exit $exit_code
    }
    
    # Enhanced signal trapping for comprehensive coverage
    trap 'cleanup_and_exit SIGINT' INT      # Ctrl+C
    trap 'cleanup_and_exit SIGTERM' TERM    # Termination request
    trap 'cleanup_and_exit SIGHUP' HUP     # Hangup (terminal closed)
    trap 'cleanup_and_exit SIGQUIT' QUIT    # Quit signal
    trap 'cleanup_and_exit EXIT' EXIT       # Normal/abnormal exit
    
    # Set up error handling for unexpected errors
    set -E  # Enable ERR trap inheritance
    trap 'cleanup_and_exit ERROR' ERR       # Unexpected errors

    # Pre-calculate total files to sync
    total_files=0
    synced_files=0
    for pair in "${PAIRS[@]}"; do
        IFS=: read -r SRC DST <<< "$pair"
        SRC="${SRC%\"}"; SRC="${SRC#\"}"  # Trim quotes
        DST="${DST%\"}"; DST="${DST#\"}"
        if [ -e "$SRC" ]; then
            total_files_to_sync=$(get_total_files_to_sync "$SRC" "$DST")
            total_files=$((total_files + total_files_to_sync))
        fi
    done
    
    # Start job tracking
    JOB_ID=$(log_job_start)
    
    log "Starting backup of ${#PAIRS[@]} source:destination pair(s)... (Job ID: $JOB_ID)"
    log "Total files to sync: $total_files"
    
    # Track overall job success
    OVERALL_SUCCESS=true

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

        # Create temporary files for rsync output monitoring
        temp_stats="/tmp/rsync_stats_$$"
        temp_output="/tmp/rsync_output_$$"
        counter_file="/tmp/rsync_counter_$$"
        
        # Initialize counter file with current synced count
        echo "$synced_files" > "$counter_file"
        
        # Run rsync and monitor progress in real-time
        if [[ -t 1 ]]; then
            # Interactive: show progress live + log
            rsync -avL --update --progress --stats --exclude='.*' --no-times --no-perms --no-owner --no-group "$SRC" "$DST" 2>&1 | \
            tee -a "$LOGFILE" | \
            tee "$temp_stats" | \
            {
                local last_xfer_count=0
                while IFS= read -r line; do
                    echo "$line"
                    # Monitor for progress updates
                    if [[ "$line" =~ xfer#([0-9]+) ]]; then
                        local current_xfer_count="${BASH_REMATCH[1]}"
                        if [[ "$current_xfer_count" -gt "$last_xfer_count" ]]; then
                            # Calculate new synced count (base + current transfer count)
                            local base_synced_count=$(cat "$counter_file" 2>/dev/null || echo "0")
                            local new_synced_files=$((base_synced_count + current_xfer_count))
                            
                            # Update global synced_files variable through temp file
                            echo "$new_synced_files" > "${counter_file}.new"
                            
                            # Update progress checkpoint every 10 files
                            if [[ $((current_xfer_count % 10)) -eq 0 ]]; then
                                update_progress_checkpoint "$new_synced_files" "$JOB_ID"
                            fi
                            
                            last_xfer_count="$current_xfer_count"
                        fi
                    fi
                done
            }
        else
            # Non-interactive: log only
            rsync -avL --update --progress --stats --exclude='.*' --no-times --no-perms --no-owner --no-group "$SRC" "$DST" 2>&1 | \
            tee -a "$LOGFILE" | \
            tee "$temp_stats" | \
            {
                local last_xfer_count=0
                while IFS= read -r line; do
                    # Monitor for progress updates
                    if [[ "$line" =~ xfer#([0-9]+) ]]; then
                        local current_xfer_count="${BASH_REMATCH[1]}"
                        if [[ "$current_xfer_count" -gt "$last_xfer_count" ]]; then
                            # Calculate new synced count
                            local base_synced_count=$(cat "$counter_file" 2>/dev/null || echo "0")
                            local new_synced_files=$((base_synced_count + current_xfer_count))
                            
                            # Update counter file
                            echo "$new_synced_files" > "${counter_file}.new"
                            
                            # Update progress checkpoint every 10 files
                            if [[ $((current_xfer_count % 10)) -eq 0 ]]; then
                                update_progress_checkpoint "$new_synced_files" "$JOB_ID"
                            fi
                            
                            last_xfer_count="$current_xfer_count"
                        fi
                    fi
                done
            }
        fi
        RSYNC_EXIT=${PIPESTATUS[0]}
        
        # Read the updated synced count from the counter file
        if [[ -f "${counter_file}.new" ]]; then
            synced_files=$(cat "${counter_file}.new")
        fi
        
        # Extract final number of transferred files from rsync stats as backup
        files_synced_this_pair=$(grep "Number of regular files transferred:" "$temp_stats" 2>/dev/null | awk '{print $NF}' || echo 0)
        
        # Ensure synced_files reflects the actual transfers
        if [[ "$files_synced_this_pair" -gt 0 ]]; then
            # If we have final stats, use base + final count to be sure
            local base_count_for_pair=$(cat "$counter_file" 2>/dev/null || echo "0")
            synced_files=$((base_count_for_pair + files_synced_this_pair))
        fi
        
        # Final progress checkpoint for this pair
        update_progress_checkpoint "$synced_files" "$JOB_ID"
        
        # Clean up temp files
        rm -f "$temp_stats" "$temp_output" "$counter_file" "${counter_file}.new"
        
        if [ $RSYNC_EXIT -eq 0 ]; then
            log "Backup of $SRC → $DST completed successfully. Files synced: $files_synced_this_pair"
        else
            log "Backup of $SRC → $DST failed with errors (rsync exit code $RSYNC_EXIT). Files synced: $files_synced_this_pair"
            OVERALL_SUCCESS=false
        fi
    done

    # Calculate unsynced files and log job completion
    unsynced_files=$((total_files - synced_files))
    if [ "$OVERALL_SUCCESS" = true ]; then
        # All successful - no unsynced files
        log_job_end "$JOB_ID" "SUCCESS" "$unsynced_files"
        log "All source:destination pairs processed successfully. (Job ID: $JOB_ID)"
    else
        # Some failed - log remaining unsynced files
        log_job_end "$JOB_ID" "FAILED" "$unsynced_files"
        log "Backup job completed with errors. Unsynced files: $unsynced_files (Job ID: $JOB_ID)"
    fi
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
    # Check if backup is currently running
    local is_running=false
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        is_running=true
    fi
    
    # Look for files that were actually transferred in rsync output
    # Rsync shows files being transferred as simple paths like "2024/082024 - Alaska/P8310074.MOV"
    local all_files=$(grep -iE '^[0-9]{4}/.*\.(jpg|jpeg|png|gif|mov|mp4|avi|mkv|pdf|doc|docx|txt|md|sh|py|js|html|css|json|xml|zip|tar|gz|dmg|pkg|app|heic|cr2|raw|tiff|psd)$' "$LOGFILE" | grep -v "^rsync:" | grep -v "rename" 2>/dev/null)
    
    if [[ -n "$all_files" ]]; then
        if [ "$is_running" = true ]; then
            # If running, get the second-to-last file (last completed file)
            last_transferred_file=$(echo "$all_files" | tail -2 | head -1)
        else
            # If not running, get the last file
            last_transferred_file=$(echo "$all_files" | tail -1)
        fi
    fi
    
    # If no files found with year prefix, try a broader search
    if [[ -z "$last_transferred_file" ]]; then
        all_files=$(grep -E '\.(jpg|jpeg|png|gif|mov|mp4|avi|mkv|pdf|doc|docx|txt|md|sh|py|js|html|css|json|xml|zip|tar|gz|dmg|pkg|app|heic|cr2|raw|tiff|psd)$' "$LOGFILE" | grep -v "^rsync:" | grep -v "rename" | grep -v "building file list" | grep -v "total size" 2>/dev/null)
        
        if [[ -n "$all_files" ]]; then
            if [ "$is_running" = true ]; then
                # If running, get the second-to-last file
                last_transferred_file=$(echo "$all_files" | tail -2 | head -1)
            else
                # If not running, get the last file
                last_transferred_file=$(echo "$all_files" | tail -1)
            fi
            
            # Clean up any leading/trailing whitespace
            if [[ -n "$last_transferred_file" ]]; then
                last_transferred_file=$(echo "$last_transferred_file" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            fi
        fi
    fi
    
    if [[ -z "$last_transferred_file" ]]; then
        last_transferred_file="None found"
    fi
    
    echo "$last_transferred_file"
}

# === Show status ===
show_status() {
    echo "==> NAS Backup Status"
    
    # Check mount status
    if mount | grep -q "/Users/ryanhoulihan/Library/Volumes/NAS"; then
        mount_path="/Users/ryanhoulihan/Library/Volumes/NAS"
        mount_status="✅ Mounted"
    elif [ -d "/Volumes/home" ] && mount | grep -q "/Volumes/home"; then
        mount_path="/Volumes/home"
        mount_status="✅ Mounted"
    else
        mount_path="Not available"
        mount_status="❌ Not mounted"
    fi
    
    echo "  Mount Point:     $mount_path"
    echo "  Mount Status:    $mount_status"
    echo
    
    # Check if backup is currently running
    local is_running=false
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        is_running=true
    fi
    
    if [ -f "$LOGFILE" ]; then
        # Get last backup activity
        last_start=$(grep "Starting backup" "$LOGFILE" | tail -n 1)
        last_success=$(grep "completed successfully" "$LOGFILE" | tail -n 1)
        last_fail=$(grep "failed with errors" "$LOGFILE" | tail -n 1)
        
        # Determine last run time
        if [[ -n "$last_start" ]]; then
            last_run_time=$(echo "$last_start" | awk '{print $1, $2}')
        else
            last_run_time="Never"
        fi
        
        # Determine backup status
        if [ "$is_running" = true ]; then
            backup_status="🔄 Currently running (started $last_run_time)"
        elif [[ -n "$last_success" ]] && [[ -n "$last_fail" ]]; then
            # Compare timestamps to see which is more recent
            success_time=$(echo "$last_success" | awk '{print $1, $2}')
            fail_time=$(echo "$last_fail" | awk '{print $1, $2}')
            if [[ "$success_time" > "$fail_time" ]]; then
                backup_status="✅ Last run successful ($last_run_time)"
            else
                exit_code=$(echo "$last_fail" | grep -o 'exit code [0-9]*' | grep -o '[0-9]*')
                backup_status="⚠️ Last run failed ($last_run_time, exit code $exit_code)"
            fi
        elif [[ -n "$last_success" ]]; then
            backup_status="✅ Last run successful ($last_run_time)"
        elif [[ -n "$last_fail" ]]; then
            exit_code=$(echo "$last_fail" | grep -o 'exit code [0-9]*' | grep -o '[0-9]*')
            backup_status="⚠️ Last run failed ($last_run_time, exit code $exit_code)"
        elif [[ "$last_run_time" != "Never" ]]; then
            backup_status="❔ Status unknown ($last_run_time)"
        else
            backup_status="✅ Idle (no previous runs)"
        fi

        # Get number of files left to sync from rsync progress output
        if [ "$is_running" = true ]; then
            # Extract the most recent "to-check" count from rsync progress output
            # Format: "   123456789 100%    5.08MB/s    0:02:37 (xfer#10, to-check=34412/35182)"
            files_left=$(grep 'to-check=' "$LOGFILE" | tail -n 1 | grep -o 'to-check=[0-9]*/[0-9]*' | cut -d'=' -f2 | cut -d'/' -f1)
            if [[ -z "$files_left" ]]; then
                files_left="Unknown"
            fi
        else
            files_left="N/A"
        fi

        # Get last synced file
        last_synced_file=$(get_last_synced_file)
        if [[ -z "$last_synced_file" ]]; then
            last_synced_file="None found"
        fi
        
        echo "==> Backup Status"
        echo "  Status:          $backup_status"
        
        # Show last job run info if available and not currently running
        if [ "$is_running" = false ] && [ -f "$JOB_STATUS_FILE" ]; then
            last_job_end=$(grep "^JOB_END" "$JOB_STATUS_FILE" | tail -n 1)
            if [[ -n "$last_job_end" ]]; then
                IFS='|' read -r _ job_id timestamp status unsynced_files <<<"$last_job_end"
                echo "  Last Job ID:     $job_id"
                echo "  Last Job Status: $status"
                # Only show unsynced files if greater than 0
                if [[ "$unsynced_files" -gt 0 ]]; then
                    echo "  Unsynced Files:  $unsynced_files"
                fi
            fi
        fi
        echo
        
        echo "==> Last Synced File"
        echo "  File:            $last_synced_file"
        if [ "$is_running" = true ]; then
            echo "  Files Left:      $files_left"
        fi
        
    else
        if [ "$is_running" = true ]; then
            backup_status="🔄 Currently running (no log file)"
        else
            backup_status="✅ Idle (no log file)"
        fi
        
        echo "==> Backup Status"
        echo "  Status:          $backup_status"
        echo
        
        echo "==> Last Synced File"
        echo "  File:            None found"
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
    history)
        echo "🔍 Job Run History:"
        cat "$JOB_STATUS_FILE" | while read -r line; do
            echo "🕒 $line"
        done
        ;;
    *)
        echo "Usage: $0 [run <source:dest> ...|run --list=file|last [count]|status|history]"
        exit 1
        ;;
esac
