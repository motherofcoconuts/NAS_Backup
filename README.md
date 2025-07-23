
## What it is
- Auto mounts TrevorNAS if available
- If TrevorNAS is mounted to the mount point (`/Volumes/home`) then it auto syncs files as defined in `~/Library/LaunchAgents/com.ryanhoulihan.backuptoNAS.plist`
- Uses `rsync` to sync files efficiently, preserving links and metadata.
- Logs all activity to `~/Library/Logs/nasbackup.log`, including start/end times, per-pair results, and rsync output.
- Prevents multiple concurrent runs with a lockfile (`/tmp/nasbackup.lock`).
- Provides CLI tool through `backup_to_nas`
## Running the Script
## 📦 Run Backups

###  Single pair
```bash
./backup_to_nas.sh run "/path/to/source:/path/to/destination"
```
### Multi pair
```bash
./backup_to_nas.sh run "/src1:/dst1" "/src2:/dst2"
```
### Status
```bash
./backup_to_nas.sh status
```

**Note**: The status command now shows `Unsynced Files` count when greater than 0, helping administrators identify incomplete backups.
### Logs

```bash
tail -n 50 ~/Library/Logs/nasbackup.log
```

### Setup
Register tool as CLI tool
```bash
sudo ln -s ~/Development/Scripts/backup_to_nas.sh /usr/local/bin/backup_to_nas
```

## Documentation

- **[API Reference](docs/API_REFERENCE.md)**: Complete API documentation for the status server
- **[User Guide](docs/USER_GUIDE.md)**: Comprehensive user guide with examples and best practices
- **[Changelog](CHANGELOG.md)**: Release notes and version history

## Launch Agent
Wrote a launch agent  `mountNAS` to mount the NAS and `backuptoNAS` which checks if the NAS volume is mounted and if so runs rsync.

**Start Launch Agent**
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ryanhoulihan.mountNAS.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ryanhoulihan.backuptoNAS.plist
```
**Stop Launch Agent**
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.ryanhoulihan.mountNAS.plist
	launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.ryanhoulihan.backuptoNAS.plist
```
