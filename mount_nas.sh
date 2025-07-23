#!/bin/bash

# === CONFIG ===
NAS_SHARE="//ryguy@TrevorNAS/home"    # SMB share
MOUNT_PARENT="/Users/ryanhoulihan/Library/Volumes"               # Parent dir for mount point
MOUNT_NAME="NAS"
MOUNT_POINT="$MOUNT_PARENT/$MOUNT_NAME"

# === LOG FUNCTION ===
log() {
    echo "NASMount: $1"
    logger "NASMount: $1"
}

# === CREATE MOUNT POINT ===
log "Creating mount point at $MOUNT_POINT"
mkdir -p "$MOUNT_POINT" || {
    log "Failed to create mount point."
    exit 1
}

# === MOUNT SMB SHARE ===
log "Mounting $NAS_SHARE to $MOUNT_POINT"
if mount_smbfs "$NAS_SHARE" "$MOUNT_POINT"; then
    log "Successfully mounted NAS at $MOUNT_POINT"
else
    log "Failed to mount NAS."
    rmdir "$MOUNT_POINT"
    exit 1
fi

# === WAIT UNTIL UNMOUNTED ===
while mount | grep -q "$MOUNT_POINT"; do
    if ! nc -G 2 -z TrevorNAS 445; then
        logger "NASMount: Network down or TrevorNAS unreachable."
        umount -f "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
        exit 1
    fi
    sleep 5
done

# === CLEANUP ===
log "Unmount detected. Cleaning up $MOUNT_POINT"
rmdir "$MOUNT_POINT"
log "Cleanup complete."
