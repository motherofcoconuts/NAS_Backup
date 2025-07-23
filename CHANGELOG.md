# Changelog

All notable changes to the NAS Backup System will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2024-07-23

### Added
- **Enhanced Backup Status Tracking**: Added `unsynced_files` field to backup job status tracking
  - Tracks the number of files that were not successfully synced during backup jobs
  - Available in both job status logs and API responses
  - Provides administrators with detailed diagnostic information for failed or incomplete backups

### Changed
- **Job Status Format**: Updated `JOB_END` log format to include unsynced file count
  - Old format: `JOB_END|job_id|timestamp|status`
  - New format: `JOB_END|job_id|timestamp|status|unsynced_files`
- **Status API Response**: Enhanced `/api/status/last-run` endpoint to include `unsynced_files` field
- **Status Command Output**: Updated `backup_to_nas status` command to display unsynced files when > 0

### Enhanced
- **Real-time Progress Tracking**: Improved file counting accuracy during backup operations
- **Error Handling**: Enhanced signal handling to properly track unsynced files on interruption
- **Diagnostic Capabilities**: Administrators can now identify partial backup failures and performance issues

### Administrative Benefits
The new `unsynced_files` field enables administrators to:
- **Detect Incomplete Backups**: Identify when backups appear successful but have missing files
- **Diagnose Network Issues**: Track when connectivity problems cause partial sync failures  
- **Monitor Disk Space**: Identify when destination storage limitations prevent complete backups
- **Assess Permission Problems**: Detect when file access issues cause sync failures
- **Track Large Job Progress**: Monitor progress of lengthy backup operations over time
- **Set Up Alerts**: Create monitoring alerts based on unsynced file thresholds

### Usage Examples
```bash
# Check for incomplete backups via CLI
backup_to_nas status

# Monitor via API
curl "http://localhost:8080/api/status/last-run" | jq '.unsynced_files'

# Alert on jobs with unsynced files
if [ $(curl -s "http://localhost:8080/api/status/last-run" | jq '.unsynced_files') -gt 0 ]; then
    echo "Warning: Last backup has unsynced files"
fi
```

## [1.0.0] - 2024-07-22

### Added
- Initial release of NAS Backup System
- Automated NAS mounting and file synchronization
- `rsync`-based efficient file transfer with metadata preservation
- Comprehensive logging system
- Lockfile-based concurrent run prevention
- CLI tool with multiple operation modes
- Status API server with JSON/XML support
- Launch agent integration for automated backups
- Real-time progress tracking and monitoring
