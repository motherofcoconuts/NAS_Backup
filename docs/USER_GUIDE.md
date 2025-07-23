# User Guide: NAS Backup System

The NAS Backup System allows users to automatically sync files between local directories and a NAS server using the `backup_to_nas` CLI tool.

## Features

- **Automount**: Attempts to mount the NAS server automatically if available.
- **Sync**: Uses `rsync` to sync files efficiently, preserving metadata and links.
- **Logging**: Logs all activity, including start/end times, per-pair results, and rsync output.
- **Lockfile**: Prevents multiple concurrent runs with a lockfile (`/tmp/nasbackup.lock`).

## Installation

1. Clone the repository
2. Register the tool as a CLI tool using symbolic link
   ```bash
   sudo ln -s ~/Development/Scripts/backup_to_nas.sh /usr/local/bin/backup_to_nas
   ```
3. Install the `launchctl` agents for auto-execution

## Running the Scripts

### Running Backups
- **Single Pair**
  ```bash
  backup_to_nas run "/path/to/source:/path/to/destination"
  ```
- **Multi Pair**
  ```bash
  backup_to_nas run "/src1:/dst1" "/src2:/dst2"
  ```
- **Checking Status**
  ```bash
  backup_to_nas status
  ```
- **Viewing Logs**
  ```bash
  tail -n 50 ~/Library/Logs/nasbackup.log
  ```

### New Field: `unsynced_files`

Administrators can now check the number of files not synced in the last backup job, signified by the `unsynced_files` field:
- **Field Value**: Tracks files not synced during the last job.
- **Use Cases**:
  - Detect incomplete backups even if the job status is `SUCCESS`.
  - Analyze backup performance and issues, such as network errors, disk space, and permissions.

## Error Handling

- **Log Output**: Errors and progress are continually logged.
- **Notifications**: Admins are alerted to errors with exit codes and unsynced files reported.

## Updating

Stay tuned for more features and improvements in future updates.
