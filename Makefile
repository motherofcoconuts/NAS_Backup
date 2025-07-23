# Makefile for NAS Backup Project

# Define the paths for convenience
BIN_PATH = /usr/local/bin/backup_to_nas
SCRIPT_PATH = $(shell pwd)
LAUNCH_AGENT_PATH = /Users/ryanhoulihan/Library/LaunchAgents

.PHONY: setup restart stop status help

help:
	@echo "Available commands:"
	@echo "  make setup   - Create symlinks and copy plist files"
	@echo "  make restart - Restart the launch agents"
	@echo "  make stop    - Stop the launch agents"
	@echo "  make status  - Check status of backup and mount services"
	@echo "  make help    - Show this help message"

setup:
	# Create symlink (requires sudo)
	@echo "Creating symlink (requires sudo)..."
	sudo ln -sf $(SCRIPT_PATH)/backup_to_nas.sh $(BIN_PATH)
	# Copy plist files to LaunchAgents
	cp $(SCRIPT_PATH)/com.ryanhoulihan.mountNAS.plist $(LAUNCH_AGENT_PATH)/
	cp $(SCRIPT_PATH)/com.ryanhoulihan.backuptoNAS.plist $(LAUNCH_AGENT_PATH)/
	# Start the launch agents
	launchctl bootstrap gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.mountNAS.plist || true
	launchctl bootstrap gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.backuptoNAS.plist || true
	@echo "Setup complete: Symlinks created, plist files copied, and services started."

restart:
	# Restart the launch agents
	launchctl bootout gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.mountNAS.plist || true
	launchctl bootout gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.backuptoNAS.plist || true
	launchctl bootstrap gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.mountNAS.plist
	launchctl bootstrap gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.backuptoNAS.plist
	@echo "Restart complete: Launch agents restarted."

stop:
	# Stop the launch agents
	launchctl bootout gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.mountNAS.plist || true
	launchctl bootout gui/$(shell id -u) $(LAUNCH_AGENT_PATH)/com.ryanhoulihan.backuptoNAS.plist || true
	@echo "Stop complete: Launch agents stopped."

status:
	@echo "🔍 Checking NAS backup services status..."
	@echo "Launch agents:"
	@launchctl list | grep ryanhoulihan || echo "No services found"
	@echo "\n📊 Backup status:"
	@$(BIN_PATH) status

