#!/bin/bash

set -e

if [[ "$1" == "--debug" ]]; then
  set -x
fi

if [[ "$1" == "--help" ]]; then
  echo "Usage: sudo bash setup.sh"
  echo "This script sets up a media server with the following components:"
  echo "- Formats and pools drives using MergerFS"
  echo "- Installs Jellyfin, Tdarr, Sonarr, Radarr, and Prowlarr"
  echo "- Configures Docker services (Jellyseerr, Flaresolverr, Watchtower)"
  echo "- Sets up a reverse proxy with NGINX"
  echo "- Provides a terminal menu for managing services"
  exit 0
fi

# Check for --dry-run argument
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "Dry-run mode enabled. No changes will be made."
fi

run_command() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

### 1. Compatibility Check ###
# Ensure the script is run as root and on a supported Ubuntu-based distribution.
check_compatibility() {
  if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run as root."
    exit 1
  fi

  if ! grep -qiE 'ubuntu|mint' /etc/os-release; then
    echo "[ERROR] This script only supports Ubuntu-based distributions like Ubuntu and Linux Mint."
    exit 1
  fi
}

### 2. Load Configuration ###
# Load the configuration file to set up variables and parameters.
load_config() {
  CONFIG_FILE="./config.sh"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file $CONFIG_FILE not found."
    exit 1
  fi
  source "$CONFIG_FILE"
}

# Call load_config early in the script
load_config

### 3. Create Group and Add Users ###
# Create the group for managing services and add the specified user to the group.
setup_group() {
  if ! getent group $GROUP > /dev/null; then
    echo "Creating group: $GROUP"
    run_command "groupadd $GROUP"
  else
    echo "Group '$GROUP' already exists."
  fi

  echo "Adding users to the '$GROUP' group..."
  run_command "usermod -aG $GROUP $USER"
}

# Log output
LOGFILE="/var/log/media-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

### 4. Validate Required Variables ###
# Ensure all required variables are set in the configuration file.
validate_variables() {
  REQUIRED_VARS=("MOVIES_DIR" "SERIES_DIR" "DOWNLOADS_DIR" "CONFIG_DIR" "TRANSCODE_DIR" "LOGS_DIR" "TMP_DIR" "MAX_LOG_SIZE" "DAYS_TO_KEEP_LOGS")
  for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
      echo "[ERROR] Required variable '$var' is not set. Please check your configuration."
      exit 1
    fi
  done
}

# Call validate_variables early in the script
validate_variables

# Fix heredoc blocks
run_command "cat <<EOF > /etc/docker/daemon.json
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"${MAX_LOG_SIZE}m\",
    \"max-file\": \"3\"
  }
}
EOF"

run_command "cat <<EOF > /etc/logrotate.d/media-services
/var/log/jellyfin/*.log
/var/log/sonarr/*.log
/var/log/radarr/*.log
/var/log/prowlarr/*.log {
    daily
    rotate ${DAYS_TO_KEEP_LOGS}
    compress
    missingok
    notifempty
    copytruncate
}
EOF"

if [ "$ENABLE_FORMAT_AND_PARTITIONING" = true ]; then
  ### 5. Format Drives and Setup MergerFS ###
  # Format the specified drives, mount them, and create a MergerFS pool.
  read -p "Are you sure you want to format ${DRIVES[*]}? This will erase ALL data. (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborting..."
    exit 1
  fi

  read -p "This will erase ALL data on the drives. Type 'FORMAT' to confirm: " confirm_format
  if [[ "$confirm_format" != "FORMAT" ]]; then
    echo "Aborting..."
    exit 1
  fi

  echo "Setting up drives..."
  if mount | grep -q "$MERGERFS_POOL"; then
    echo "MergerFS is already mounted at $MERGERFS_POOL. Skipping drive setup."
  else
    for i in "${!DRIVES[@]}"; do
      run_command "umount ${DRIVES[$i]} || true"
      run_command "mkfs.ext4 -F ${DRIVES[$i]}"
      run_command "mkdir -p \"${MOUNT_POINTS[$i]}\""
      run_command "mount \"${DRIVES[$i]}\" \"${MOUNT_POINTS[$i]}\""
    done

    run_command "apt-get update"
    run_command "apt-get install -y mergerfs cron fuse3"
    run_command "systemctl enable --now cron"

    # Clear all mount points
    for mount_point in "${MOUNT_POINTS[@]}"; do
      if [ -d "$mount_point" ] && [ "$(ls -alh "$mount_point" 2>/dev/null)" ]; then
        echo "Clearing mount point: $mount_point"
        run_command "rm -rf \"$mount_point\"/*"
      fi
    done

    # Clear the MergerFS pool directory
    if [ -d "$MERGERFS_POOL" ] && [ "$(ls -alh "$MERGERFS_POOL" 2>/dev/null)" ]; then
      echo "$MERGERFS_POOL is not empty. Clearing it..."
      run_command "rm -rf \"$MERGERFS_POOL\"/*"
    fi

  # Fix the mergerfs command to handle mount points correctly
  MOUNT_POINTS_JOINED=$(IFS=:; echo "${MOUNT_POINTS[*]}")
  run_command "mergerfs -o defaults,allow_other,use_ino \"$MOUNT_POINTS_JOINED\" \"$MERGERFS_POOL\""

  if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to mount MergerFS. Please check the mount points and try again."
    exit 1
  fi

  if ! grep -q "$MERGERFS_POOL fuse.mergerfs" /etc/fstab; then
    run_command "echo \"$MOUNT_POINTS_JOINED $MERGERFS_POOL fuse.mergerfs defaults,allow_other,use_ino 0 0\" >> /etc/fstab"
  else
    echo "[INFO] MergerFS entry already exists in /etc/fstab. Skipping addition."
  fi

  if [ "$DRY_RUN" != true ]; then
    if ! mergerfs -o defaults,allow_other,use_ino "$MOUNT_POINTS_JOINED" "$MERGERFS_POOL"; then
      echo "Failed to mount MergerFS. Exiting..."
      exit 1
      fi
   fi
  fi
fi

### 6. Create Directory Structure ###
# Create the necessary directories for media storage, configuration, and logs.
echo "Creating folder structure..."
run_command "mkdir -p \"$MOVIES_DIR\" \"$SERIES_DIR\" \"$DOWNLOADS_DIR/movies\" \"$DOWNLOADS_DIR/series\" \
         \"$CONFIG_DIR/jellyseerr\" \"$CONFIG_DIR/recyclarr\" \"$CONFIG_DIR/flaresolverr\" \"$TRANSCODE_DIR\" \"$LOGS_DIR\" \"$TMP_DIR\""
run_command "chown -R $USER:$GROUP \"$MOVIES_DIR\" \"$SERIES_DIR\" \"$DOWNLOADS_DIR\" \"$CONFIG_DIR\" \"$TRANSCODE_DIR\" \"$LOGS_DIR\" \"$TMP_DIR\""
run_command "chmod -R g+rw \"$MOVIES_DIR\" \"$SERIES_DIR\" \"$DOWNLOADS_DIR\" \"$CONFIG_DIR\" \"$TRANSCODE_DIR\" \"$LOGS_DIR\" \"$TMP_DIR\""

### 7. System Update & Essentials ###
# Update the system and install essential packages.
run_command "apt-get update && apt-get upgrade -y"
run_command "apt install -y curl gnupg lsb-release software-properties-common unzip ufw fail2ban git xdg-utils jq"

### 8. Install Jellyfin ###
# Install and configure Jellyfin, a media server for streaming content.
if [ "$ENABLE_JELLYFIN" = true ]; then
  echo "Installing Jellyfin..."

  # Validate architecture
  SUPPORTED_ARCHITECTURES="amd64 armhf arm64"
  ARCHITECTURE=$(dpkg --print-architecture)
  if ! echo "$SUPPORTED_ARCHITECTURES" | grep -qw "$ARCHITECTURE"; then
    echo "[ERROR] Unsupported architecture: $ARCHITECTURE. Supported architectures are: $SUPPORTED_ARCHITECTURES."
    exit 1
  fi

  # Determine OS and version
  if [ ! -f /etc/os-release ]; then
    echo "[ERROR] /etc/os-release not found. This script supports Debian-based distributions only."
    exit 1
  fi

  . /etc/os-release
  if [ "$ID" = "raspbian" ]; then
    REPO_OS="debian"
    VERSION="$VERSION_CODENAME"
  elif [ "$ID" = "neon" ]; then
    REPO_OS="ubuntu"
    VERSION="$VERSION_CODENAME"
  elif [ -n "$UBUNTU_CODENAME" ]; then
    REPO_OS="ubuntu"
    VERSION="$UBUNTU_CODENAME"
  elif [ -n "$DEBIAN_CODENAME" ]; then
    REPO_OS="debian"
    VERSION="$DEBIAN_CODENAME"
  else
    echo "[ERROR] Unsupported OS: $ID. This script supports Debian and Ubuntu-based distributions only."
    exit 1
  fi

  echo "Detected OS: $REPO_OS $VERSION, Architecture: $ARCHITECTURE"

  # Add Jellyfin repository
  echo "Adding Jellyfin repository..."
  run_command "mkdir -p /etc/apt/keyrings"
  run_command "curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg"
  run_command "cat <<EOF > /etc/apt/sources.list.d/jellyfin.sources
Types: deb
URIs: https://repo.jellyfin.org/$REPO_OS
Suites: $VERSION
Components: main
Architectures: $ARCHITECTURE
Signed-By: /etc/apt/keyrings/jellyfin.gpg
EOF"

  # Update repositories and install Jellyfin
  echo "Updating APT repositories..."
  run_command "apt update"
  echo "Installing Jellyfin..."
  run_command "apt install -y jellyfin"

  # Verify installation
  echo "Verifying Jellyfin installation..."
  if systemctl is-active --quiet jellyfin; then
    echo "Jellyfin is running. Access it at http://localhost:$JELLYFIN_PORT"
  else
    echo "[ERROR] Jellyfin failed to start. Check the logs for details."
    exit 1
  fi
fi

if [ "$ENABLE_JELLYFIN_HEALTHCHECK" = true ]; then
  echo "Adding Jellyfin health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$JELLYFIN_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$JELLYFIN_PORT || systemctl restart jellyfin") | crontab -
  fi
fi

### 9. Install Tdarr ###
# Install and configure Tdarr for media transcoding and optimization.
if [ "$ENABLE_TDARR" = true ]; then
  echo "Installing Tdarr..."

  # Install dependencies
  echo "Installing dependencies..."
  run_command "apt-get install -y curl sudo mc handbrake-cli"
  echo "Dependencies installed."

  # Set up hardware acceleration
  echo "Setting up hardware acceleration..."
  run_command "apt-get install -y va-driver-all ocl-icd-libopencl1 intel-opencl-icd vainfo intel-gpu-tools"
  if [ -d "/dev/dri" ]; then
    run_command "chgrp video /dev/dri"
    run_command "chmod 755 /dev/dri"
    run_command "chmod 660 /dev/dri/*"
    run_command "adduser $USER video"
    run_command "adduser $USER render"
  fi
  echo "Hardware acceleration set up."

  # Install Tdarr
  echo "Installing Tdarr..."
  run_command "mkdir -p /opt/tdarr"
  run_command "cd /opt/tdarr"
  RELEASE=$(curl -s https://f000.backblazeb2.com/file/tdarrs/versions.json | grep -oP '(?<=\"Tdarr_Updater\": \")[^\"]+' | grep linux_x64 | head -n 1)
  run_command "wget -q $RELEASE -O Tdarr_Updater.zip"
  run_command "unzip Tdarr_Updater.zip"
  run_command "rm -rf Tdarr_Updater.zip"
  run_command "chmod +x Tdarr_Updater"
  run_command "./Tdarr_Updater &>/dev/null"
  echo "Tdarr installed."

  # Create systemd services
  echo "Creating Tdarr services..."
  run_command "cat <<EOF > /etc/systemd/system/tdarr-server.service
[Unit]
Description=Tdarr Server Daemon
After=network.target

[Service]
User=$USER
Group=$GROUP
Type=simple
WorkingDirectory=/opt/tdarr/Tdarr_Server
ExecStartPre=/opt/tdarr/Tdarr_Updater
ExecStart=/opt/tdarr/Tdarr_Server/Tdarr_Server
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF"

  run_command "cat <<EOF > /etc/systemd/system/tdarr-node.service
[Unit]
Description=Tdarr Node Daemon
After=network.target
Requires=tdarr-server.service

[Service]
User=$USER
Group=$GROUP
Type=simple
WorkingDirectory=/opt/tdarr/Tdarr_Node
ExecStart=/opt/tdarr/Tdarr_Node/Tdarr_Node
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF"

  run_command "systemctl daemon-reload"
  run_command "systemctl enable --now tdarr-server.service"
  run_command "systemctl enable --now tdarr-node.service"
  echo "Tdarr services created and started."

  # Clean up
  echo "Cleaning up..."
  run_command "apt-get -y autoremove"
  run_command "apt-get -y autoclean"
  echo "Clean up complete."
fi

if systemctl list-units --full --all | grep -q "^tdarr-server.service"; then
  echo "Tdarr Server service already exists. Skipping..."
else
  run_command "cat <<EOF | sudo tee /etc/systemd/system/tdarr-server.service > /dev/null
[Unit]
Description=Tdarr Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/tdarr/Tdarr_Server
ExecStart=/usr/bin/node /opt/tdarr/Tdarr_Server/Tdarr_Server.js
Restart=always
RestartSec=10
User=$USER
Group=$GROUP

[Install]
WantedBy=multi-user.target
EOF"
fi

if systemctl list-units --full --all | grep -q "^tdarr-node.service"; then
  echo "Tdarr Node service already exists. Skipping..."
else
  run_command "cat <<EOF | sudo tee /etc/systemd/system/tdarr-node.service > /dev/null
[Unit]
Description=Tdarr Node
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/tdarr/Tdarr_Node
ExecStart=/usr/bin/node /opt/tdarr/Tdarr_Node/Tdarr_Node.js
Restart=always
RestartSec=10
User=$USER
Group=$GROUP

[Install]
WantedBy=multi-user.target
EOF"
fi

  run_command "chown -R $USER:$GROUP /opt/tdarr"
  run_command "chmod -R g+rw /opt/tdarr"

  run_command "sudo systemctl daemon-reload"
  run_command "sudo systemctl enable tdarr-server"
  run_command "sudo systemctl enable tdarr-node"

if [ "$ENABLE_TDARR_HEALTHCHECK" = true ]; then
  echo "Adding Tdarr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:8265"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:8265 || systemctl restart tdarr") | crontab -
  fi
fi

# Install Tdarr OneFlow if specified
if [ "$INSTALL_TDARR_ONEFLOW" = true ]; then
  echo "Downloading and configuring Tdarr OneFlow..."
  
  # Clone the Tdarr OneFlow repository
  run_command "git clone https://github.com/samssausages/Tdarr-One-Flow.git /opt/tdarr-oneflow"

  # Provide instructions for manual setup
  echo "Tdarr OneFlow has been downloaded to /opt/tdarr-oneflow."
  echo "To complete the setup, follow the instructions in the README file at /opt/tdarr-oneflow."
  echo "1. Go to http://localhost:8265 and go to Flows paste the text from all the yml files one by one."
  echo "2. Configure all settings in the 1.Input file at http://localhost:8265 - Flows ."
  echo "3. Add required settings at library - variables list off variables and required variables is in the README file."
fi

### 10. Install Sonarr, Radarr, and Prowlarr ###
# Install and configure Sonarr, Radarr, and Prowlarr for managing TV shows, movies, and indexers.
echo "Installing Sonarr, Radarr, and Prowlarr from official sources..."

# Install prerequisites
run_command "apt install -y curl gnupg ca-certificates apt-transport-https"

# Sonarr
if [ "$ENABLE_SONARR" = true ]; then
  echo "Installing Sonarr..."
  app="sonarr"
  app_port="8989"
  app_prereq="curl sqlite3 wget"
  app_umask="0002"
  branch="main"

  # Constants
  installdir="/opt"              # Install Location
  bindir="${installdir}/${app^}" # Full Path to Install Location
  datadir="/var/lib/$app/"       # AppData directory to use
  app_bin=${app^}                # Binary Name of the app

  # Stop the App if running
  if service --status-all | grep -Fq "$app"; then
    run_command "systemctl stop $app"
    run_command "systemctl disable $app.service"
    echo "Stopped existing $app"
  fi

  # Create AppData Directory
  run_command "mkdir -p $datadir"
  run_command "chown -R $USER:$GROUP $datadir"
  run_command "chmod 775 $datadir"
  echo "Directories created"

  # Install prerequisite packages
  echo "Installing pre-requisite packages..."
  run_command "apt update && apt install -y $app_prereq"

  # Determine architecture and download the appropriate binary
  ARCH=$(dpkg --print-architecture)
  dlbase="https://services.sonarr.tv/v1/download/$branch/latest?version=4&os=linux"
  case "$ARCH" in
    "amd64") DLURL="${dlbase}&arch=x64" ;;
    "armhf") DLURL="${dlbase}&arch=arm" ;;
    "arm64") DLURL="${dlbase}&arch=arm64" ;;
    *)
      echo "[ERROR] Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  echo "Downloading Sonarr from: $DLURL"
  run_command "wget -O Sonarr.tar.gz \"$DLURL\""
  if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to download Sonarr. Exiting..."
    exit 1
  fi

  # Verify the downloaded file is a valid tar.gz
  if ! file Sonarr.tar.gz | grep -q "gzip compressed data"; then
    echo "[ERROR] The downloaded file is not a valid tar.gz. Please check the URL or the server response."
    exit 1
  fi

  # Extract the downloaded file
  echo "Extracting Sonarr..."
  run_command "tar -xvzf Sonarr.tar.gz"
  if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to extract Sonarr. Exiting..."
    exit 1
  fi

  # Remove existing installation and install the new version
  echo "Removing existing installation..."
  run_command "rm -rf $bindir"
  echo "Installing Sonarr..."
  run_command "mv ${app^} $installdir"
  run_command "chown -R $USER:$GROUP $bindir"
  run_command "chmod 775 $bindir"
  run_command "rm -rf Sonarr.tar.gz"
  run_command "touch $datadir/update_required"
  run_command "chown $USER:$GROUP $datadir/update_required"
  echo "Sonarr installed"

  # Configure Autostart
  echo "Creating service file for Sonarr..."
  run_command "cat <<EOF > /etc/systemd/system/$app.service
[Unit]
Description=${app^} Daemon
After=syslog.target network.target
[Service]
User=$USER
Group=$GROUP
UMask=$app_umask
Type=simple
ExecStart=$bindir/$app_bin -nobrowser -data=$datadir
TimeoutStopSec=20
KillMode=process
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF"

  # Start the App
  echo "Starting Sonarr..."
  run_command "systemctl daemon-reload"
  run_command "systemctl enable --now $app"

  # Verify installation
  host=$(hostname -I)
  ip_local=$(grep -oP '^\S*' <<<"$host")
  STATUS="$(systemctl is-active "$app")"
  if [ "$STATUS" = "active" ]; then
    echo "Sonarr is running. Access it at http://$ip_local:$app_port"
  else
    echo "[ERROR] Sonarr failed to start"
  fi
fi

if [ "$ENABLE_SONARR_HEALTHCHECK" = true ]; then
  echo "Adding Sonarr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$SONARR_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$SONARR_PORT || systemctl restart sonarr") | crontab -
  fi 
fi

# Radarr
if [ "$ENABLE_RADARR" = true ]; then
  echo "Installing Radarr..."
  RADARR_URL=$(curl -s https://api.github.com/repos/Radarr/Radarr/releases/latest \
  | grep browser_download_url \
  | grep 'linux-core-x64.tar.gz' \
  | cut -d '"' -f 4)

  run_command "mkdir -p /opt/radarr"
  run_command "curl -L \"$RADARR_URL\" | tar xz -C /opt/radarr"
  run_command "ln -sf /opt/radarr/Radarr /usr/bin/radarr"

  # Set ownership and permissions
  run_command "chown -R $USER:$GROUP /opt/radarr"
  run_command "chmod -R 775 /opt/radarr"

  if systemctl list-units --full -all | grep -q "^radarr.service"; then
    echo "Radarr service already exists. Skipping..."
  else
    # Create the Radarr service file
    run_command "cat <<EOF >/etc/systemd/system/radarr.service
[Unit]
Description=Radarr Daemon
After=network.target

[Service]
ExecStart=/opt/radarr/Radarr --port=$RADARR_PORT
Restart=on-failure
User=$USER
Group=$GROUP

[Install]
WantedBy=multi-user.target
EOF"
  fi

  run_command "systemctl daemon-reload"
  run_command "systemctl enable --now radarr"
fi

if [ "$ENABLE_RADARR_HEALTHCHECK" = true ]; then
  echo "Adding Radarr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$RADARR_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$RADARR_PORT || systemctl restart radarr") | crontab -
  fi
fi

# Prowlarr
if [ "$ENABLE_PROWLARR" = true ]; then
  echo "Installing Prowlarr..."
  PROWLARR_URL=$(curl -s https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest \
  | grep browser_download_url \
  | grep 'linux-core-x64.tar.gz' \
  | cut -d '"' -f 4)

  run_command "mkdir -p /opt/prowlarr"
  run_command "curl -L \"$PROWLARR_URL\" | tar xz -C /opt/prowlarr"
  run_command "ln -sf /opt/prowlarr/Prowlarr /usr/bin/prowlarr"

  # Set ownership and permissions
  run_command "chown -R $USER:$GROUP /opt/prowlarr"
  run_command "chmod -R 775 /opt/prowlarr"

  if systemctl list-units --full -all | grep -q "^prowlarr.service"; then
    echo "Prowlarr service already exists. Skipping..."
  else
    # Create the Prowlarr service file
    run_command "cat <<EOF >/etc/systemd/system/prowlarr.service
[Unit]
Description=Prowlarr Daemon
After=network.target

[Service]
ExecStart=/opt/prowlarr/Prowlarr --port=$PROWLARR_PORT
Restart=on-failure
User=$USER
Group=$GROUP

[Install]
WantedBy=multi-user.target
EOF"

  fi

  run_command "systemctl daemon-reload"
  run_command "systemctl enable --now prowlarr"
fi

if [ "$ENABLE_PROWLARR_HEALTHCHECK" = true ]; then
  echo "Adding Prowlarr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$PROWLARR_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$PROWLARR_PORT || systemctl restart prowlarr") | crontab -
  fi
fi

### 11. Install NetData ###
# Install and configure NetData for real-time system monitoring.
if [ "$ENABLE_NETDATA" = true ]; then
  echo "Installing Netdata..."
  run_command "bash <(curl -fsSL -L https://my-netdata.io/kickstart.sh) --disable-telemetry"

  # Check if Netdata was installed successfully
  if [ ! -d "/opt/netdata" ]; then
    echo "[ERROR] Netdata installation failed. Please check the logs and try again."
    exit 1
  fi

  echo "Configuring NetData port..."
  # Try both possible paths for the config file
  NETDATA_CONF="/opt/netdata/etc/netdata/netdata.conf"
  ALT_NETDATA_CONF="/opt/netdata/netdata/etc/netdata/netdata.conf"

  if [ -f "$NETDATA_CONF" ]; then
    run_command "sed -i 's|# default port = 19999|default port = $NETDATA_PORT|' $NETDATA_CONF"
    run_command "pkill netdata || true"
    run_command "/opt/netdata/usr/sbin/netdata &"
  elif [ -f "$ALT_NETDATA_CONF" ]; then
    run_command "sed -i 's|# default port = 19999|default port = $NETDATA_PORT|' $ALT_NETDATA_CONF"
    run_command "pkill netdata || true"
    run_command "/opt/netdata/netdata/usr/sbin/netdata &"
  else
    echo "[WARNING] NetData configuration file not found. Skipping port configuration."
  fi

  echo "Enabling NetData service..."
  if systemctl list-unit-files 2>/dev/null | grep -q "netdata.service"; then
    run_command "systemctl enable netdata"
    run_command "systemctl restart netdata"
  else
    echo "[INFO] Netdata systemd service not found. Running manually in background instead."
  fi
fi

if [ "$ENABLE_NETDATA_HEALTHCHECK" = true ]; then
  echo "Adding NetData health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$NETDATA_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$NETDATA_PORT || /opt/netdata/usr/sbin/netdata &") | crontab -
  fi
fi

### 12. Install Docker Services ###
# Ensure Docker Compose is installed and set up.
# This section installs Docker Compose if it is not already installed.
# It also ensures Docker is installed and running, and sets up an alias for Docker Compose v2.

# Install Docker Compose
echo "📦 Installing Docker Compose..."

# Make sure Docker is installed first
if ! command -v docker &> /dev/null; then
  echo "🚨 Docker is not installed! Installing Docker first..."
  run_command "apt update"
  run_command "apt install -y ca-certificates curl gnupg lsb-release"

  run_command "install -m 0755 -d /etc/apt/keyrings"
  run_command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  run_command "chmod a+r /etc/apt/keyrings/docker.gpg"

# Workaround for Docker not supporting Ubuntu 24.04 (Noble / Mint 22.1) yet
UBUNTU_CODENAME="jammy"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $UBUNTU_CODENAME stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

  run_command "apt update"
  run_command "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
fi

# Enable and start Docker
run_command "systemctl enable --now docker"

# Optional: create a `docker-compose` alias for Docker Compose v2
DOCKER_COMPOSE_PATH=$(find /usr -name docker-compose -type f 2>/dev/null | head -n 1)
if [ -n "$DOCKER_COMPOSE_PATH" ]; then
  ln -sf "$DOCKER_COMPOSE_PATH" /usr/local/bin/docker-compose
fi

echo "✅ Docker Compose installed as $(docker-compose version)"

# Jellyseerr
# Install and configure Jellyseerr using Docker Compose.
# This section creates a Docker Compose configuration for Jellyseerr and starts the container.

if [ "$ENABLED_JELLYSEERR" = true ]; then
  echo "Installing Jellyseerr..."
  run_command "mkdir -p /opt/jellyseerr"
run_command "cat <<EOF > /opt/jellyseerr/docker-compose.yml
services:
  jellyseerr:
    image: fallenbagel/jellyseerr
    container_name: jellyseerr
    ports:
      - "$JELLYSEERR_PORT:5055"
    volumes:
      - $CONFIG_DIR/jellyseerr:/app/config
    restart: unless-stopped
EOF"

run_command "chown -R $USER:$GROUP $CONFIG_DIR/jellyseerr"
run_command "chmod -R g+rw $CONFIG_DIR/jellyseerr"

docker compose -f /opt/jellyseerr/docker-compose.yml up -d
fi

if [ "$ENABLE_JELLYSEERR_HEALTHCHECK" = true ]; then
  echo "Adding Jellyseerr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$JELLYSEERR_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$JELLYSEERR_PORT || docker restart jellyseerr") | crontab -
  fi
fi

# Flaresolverr
# Install and configure Flaresolverr using Docker Compose.
# This section creates a Docker Compose configuration for Flaresolverr and starts the container.

if [ "$ENABLE_FLARESOLVERR" = true ]; then
  echo "Installing Flaresolverr..."
  mkdir -p /opt/flaresolverr
cat <<EOF > /opt/flaresolverr/docker-compose.yml
services:
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    ports:
      - $FLARESOLVERR_PORT:8191
    restart: unless-stopped
EOF

run_command "chown -R $USER:$GROUP $CONFIG_DIR/flaresolverr"
run_command "chmod -R g+rw $CONFIG_DIR/flaresolverr"

run_command "docker compose -f /opt/flaresolverr/docker-compose.yml up -d"
fi

if [ "$ENABLE_FLARESOLVERR_HEALTHCHECK" = true ]; then
  echo "Adding Flaresolverr health check to crontab..."
  if ! crontab -l 2>/dev/null | grep -q "curl -fs http://localhost:$FLARESOLVERR_PORT"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * curl -fs http://localhost:$FLARESOLVERR_PORT || docker restart flaresolverr") | crontab -
  fi
fi

# Watchtower
# Install and configure Watchtower using Docker Compose.
# Watchtower is used to automatically update Docker containers.

if [ "$ENABLE_WATCHTOWER" = true ]; then
  echo "Installing Watchtower..."
  run_command "mkdir -p /opt/watchtower"
run_command "cat <<EOF > /opt/watchtower/docker-compose.yml
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup
    restart: unless-stopped
EOF"

run_command "docker compose -f /opt/watchtower/docker-compose.yml up -d"
fi

### 13. Install Recyclarr ###
# Install and configure Recyclarr for syncing custom formats and quality profiles.
if [ "$ENABLE_RECYCLARR" = true ]; then
  echo "Installing Recyclarr..."
  run_command "curl -L https://github.com/Recyclarr/recyclarr/releases/latest/download/recyclarr-linux-x64 -o /usr/local/bin/recyclarr"
run_command "chmod +x /usr/local/bin/recyclarr"
run_command "cat <<EOF > $CONFIG_DIR/recyclarr/recyclarr.yml
sonarr:
  main-sonarr:
    base_url: http://localhost:$SONARR_PORT
    api_key: 
    quality_definition:
      type: series

    quality_profiles:
      - name: WEB-1080p

    custom_formats:
      - trash_ids:
          # Unwanted
          - 15a05bc7c1a36e2b57fd628f8977e2fc # AV1
          - 85c61753df5da1fb2aab6f2a47426b09 # BR-DISK
          - fbcb31d8dabd2a319072b84fc0b7249c # Extras
          - 9c11cd3f07101cdba90a2d81cf0e56b4 # LQ
          - e2315f990da2e2cbfc9fa5b7a6fcfe48 # LQ (Release Title)
          - 23297a736ca77c0fc8e70f8edd7ee56c # Upscaled
          - 47435ece6b99a0b477caf360e79ba0bb # x265 (HD)

          # Miscellaneous
          - eb3d5cc0a2be0db205fb823640db6a3c # Repack v2
          - 44e7c4de10ae50265753082e5dc76047 # Repack v3
          - ec8fa7296b64e8cd390a1600981f3923 # Repack/Proper
          - 32b367365729d530ca1c124a0b180c64 # Bad Dual Groups
          - 82d40da2bc6923f41e14394075dd4b03 # No-RlsGroup
          - e1a997ddb54e3ecbfe06341ad323c458 # Obfuscated
          - 06d66ab109d4d2eddb2794d21526d140 # Retags
          - 1b3994c551cbb92a2c781af061f4ab44 # Scene

          # General Streaming Services
          - d660701077794679fd59e8bdf4ce3a29 # AMZN
          - f67c9ca88f463a48346062e8ad07713f # ATVP
          - 77a7b25585c18af08f60b1547bb9b4fb # CC
          - 36b72f59f4ea20aad9316f475f2d9fbb # DCU
          - 89358767a60cc28783cdc3d0be9388a4 # DSNP
          - 7a235133c87f7da4c8cccceca7e3c7a6 # HBO
          - a880d6abc21e7c16884f3ae393f84179 # HMAX
          - f6cce30f1733d5c8194222a7507909bb # HULU
          - 81d1fbf600e2540cee87f3a23f9d3c1c # MAX
          - d34870697c9db575f17700212167be23 # NF
          - 1656adc6d7bb2c8cca6acfb6592db421 # PCOK
          - c67a75ae4a1715f2bb4d492755ba4195 # PMTP
          - ae58039e1319178e6be73caab5c42166 # SHO
          - 1efe8da11bfd74fbbcd4d8117ddb9213 # STAN
          - 9623c5c9cac8e939c1b9aedd32f640bf # SYFY
          - 0ac24a2a68a9700bcb7eeca8e5cd644c # iT

          # HQ Source Groups
          - d0c516558625b04b363fa6c5c2c7cfd4 # WEB Scene
          - e6258996055b9fbab7e9cb2f75819294 # WEB Tier 01
          - 58790d4e2fdcd9733aa7ae68ba2bb503 # WEB Tier 02
          - d84935abd3f8556dcd51d4f27e22d0a6 # WEB Tier 03

        assign_scores_to:
          - name: WEB-1080p

radarr:
  main-radarr:
    base_url: http://localhost:$RADARR_PORT
    api_key: 

    quality_definition:
      type: movie

    quality_profiles:
      - name: HD Bluray + WEB

    custom_formats:
      - trash_ids:
          # HQ Source Groups
          - ed27ebfef2f323e964fb1f61391bcb35  # HD Bluray Tier 01
          - c20c8647f2746a1f4c4262b0fbbeeeae  # HD Bluray Tier 02
          - 5608c71bcebba0a5e666223bae8c9227  # HD Bluray Tier 03
          - c20f169ef63c5f40c2def54abaf4438e  # WEB Tier 01
          - 403816d65392c79236dcb6dd591aeda4  # WEB Tier 02
          - af94e0fe497124d1f9ce732069ec8c3b  # WEB Tier 03

          # Miscellaneous
          - e7718d7a3ce595f289bfee26adc178f5  # Repack/Proper
          - ae43b294509409a6a13919dedd4764c4  # Repack2
          - 5caaaa1c08c1742aa4342d8c4cc463f2  # Repack3
          - b6832f586342ef70d9c128d40c07b872  # Bad Dual Groups
          - cc444569854e9de0b084ab2b8b1532b2  # Black and White Editions
          - 90cedc1fea7ea5d11298bebd3d1d3223  # EVO (no WEBDL)
          - ae9b7c9ebde1f3bd336a8cbd1ec4c5e5  # No-RlsGroup
          - 7357cf5161efbf8c4d5d0c30b4815ee2  # Obfuscated
          - 5c44f52a8714fdd79bb4d98e2673be1f  # Retags
          - f537cf427b64c38c8e36298f657e4828  # Scene

          # Unwanted
          - ed38b889b31be83fda192888e2286d83  # BR-DISK
          - e6886871085226c3da1830830146846c  # Generated Dynamic HDR
          - 90a6f9a284dff5103f6346090e6280c8  # LQ
          - e204b80c87be9497a8a6eaff48f72905  # LQ (Release Title)
          - dc98083864ea246d05a42df0d05f81cc  # x265 (HD)
          - b8cd450cbfa689c0259a01d9e29ba3d6  # 3D
          - 0a3f082873eb454bde444150b70253cc  # Extras
          - 712d74cd88bceb883ee32f773656b1f5  # Sing-Along Versions
          - cae4ca30163749b891686f95532519bd  # AV1

          # General Streaming Services
          - b3b3a6ac74ecbd56bcdbefa4799fb9df  # AMZN
          - 40e9380490e748672c2522eaaeb692f7  # ATVP
          - cc5e51a9e85a6296ceefe097a77f12f4  # BCORE
          - 16622a6911d1ab5d5b8b713d5b0036d4  # CRiT
          - 84272245b2988854bfb76a16e60baea5  # DSNP
          - 509e5f41146e278f9eab1ddaceb34515  # HBO
          - 5763d1b0ce84aff3b21038eea8e9b8ad  # HMAX
          - 526d445d4c16214309f0fd2b3be18a89  # Hulu
          - e0ec9672be6cac914ffad34a6b077209  # iT
          - 6a061313d22e51e0f25b7cd4dc065233  # MAX
          - 2a6039655313bf5dab1e43523b62c374  # MA
          - 170b1d363bd8516fbf3a3eb05d4faff6  # NF
          - e36a0ba1bc902b26ee40818a1d59b8bd  # PMTP
          - c9fd353f8f5f1baf56dc601c4cb29920  # PCOK
          - c2863d2a50c9acad1fb50e53ece60817  # STAN

        assign_scores_to:
          - name: HD Bluray + WEB
EOF"
fi

echo "Please update the Sonarr and Radarr API keys in $CONFIG_DIR/recyclarr/recyclarr.yml after installation."

### 14. Install NGINX + Certbot + DDNS ###
# Install and configure NGINX, Certbot, and DDNS.
# This section sets up NGINX as a reverse proxy, configures dynamic DNS using ddclient,
# and enables HTTPS using Certbot.

# Install required packages
run_command "apt install -y nginx certbot python3-certbot-nginx ddclient"

# Configure ddclient for dynamic DNS
run_command "cat <<EOF > /etc/ddclient.conf
protocol=dyndns2
use=web
server=$DDNS_SERVER
login=$DDNS_LOGIN
password=$DDNS_PASSWORD
$SERVER_NAME
EOF"

run_command "systemctl enable --now ddclient"

# Check if required variables are set
if [ -z "$SERVER_NAME" ] || [ -z "$NGINX_NAME" ]; then
  echo "[ERROR] SERVER_NAME or NGINX_NAME is not set. Please check your configuration."
  exit 1
fi

NGINX_CONF_PATH="/etc/nginx/sites-available/$NGINX_NAME"

# Backup existing config
if [ -f "$NGINX_CONF_PATH" ]; then
  run_command "mv $NGINX_CONF_PATH ${NGINX_CONF_PATH}.bak"
  echo "Backed up old NGINX config to ${NGINX_CONF_PATH}.bak"
fi

# Start NGINX config
cat > "$NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
EOF

# Append reverse proxy blocks for each enabled service
# Dynamically generate NGINX configuration blocks for each service listed in NGINX_SERVICES.

append_service_block() {
  local name="$1"
  local port="$2"
  cat >> "$NGINX_CONF_PATH" <<EOF
    location /$name {
        proxy_pass http://localhost:$port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
}

# Loop through services
for service in "${NGINX_SERVICES[@]}"; do
  port_var="${service^^}_PORT" # Converts to uppercase, e.g., jellyfin -> JELLYFIN_PORT
  port="${!port_var}"          # Indirect variable reference
  if [ -n "$port" ]; then
    append_service_block "$service" "$port"
  else
    echo "[WARNING] No port set for $service (expected \$${port_var})"
  fi
done

# Close server block
echo "}" >> "$NGINX_CONF_PATH"

# Enable site
run_command "ln -sfn $NGINX_CONF_PATH /etc/nginx/sites-enabled/$NGINX_NAME"

# Validate NGINX
# Check the NGINX configuration for syntax errors and reload the service if valid.

if ! nginx -t; then
  echo "[ERROR] Invalid NGINX configuration. Check $NGINX_CONF_PATH."
  exit 1
fi

# Reload NGINX
run_command "systemctl restart nginx"

# Setup HTTPS with Certbot
# Use Certbot to obtain and configure an SSL certificate for the server.

run_command "certbot --nginx -d $SERVER_NAME --non-interactive --agree-tos -m $EMAIL"

# Optional: enable auto-renewal
run_command "systemctl enable certbot.timer"

### 15. Configure UFW & Fail2Ban ###
# Configure UFW (Uncomplicated Firewall) to allow NGINX traffic and enable Fail2Ban for security.

run_command "ufw allow 'Nginx Full'"
run_command "ufw --force enable"
run_command "systemctl enable --now fail2ban"

### 16. Create Terminal Menu ###
# Create a terminal-based menu for managing services.
# This menu allows the user to check the status of services, restart them, or open their web UIs.

run_command "cat <<EOF > /usr/local/bin/media-setup
#!/bin/bash
PS3=\"Select an option: \"
select opt in \"Jellyfin\" \"Tdarr\" \"Sonarr\" \"Radarr\" \"qBittorrent\" \"Prowlarr\" \"Jellyseerr\" \"Flaresolverr\" \"Watchtower\" \"Open Web UI\" \"Restart Service\" \"Check Services\" \"Exit\"; do
  case \$opt in
    \"Jellyfin\") systemctl status jellyfin;;
    \"Tdarr\") ps aux | grep Tdarr;;
    \"Sonarr\") systemctl status sonarr;;
    \"Radarr\") systemctl status radarr;;
    \"qBittorrent\") systemctl status qbittorrent-nox;;
    \"Prowlarr\") systemctl status prowlarr;;
    \"Jellyseerr\") docker ps | grep jellyseerr;;
    \"Flaresolverr\") docker ps | grep flaresolverr;;
    \"Watchtower\") docker ps | grep watchtower;;
    \"Open Web UI\")
      echo \"Select a service to open:\"
      select service in \"Jellyfin\" \"Sonarr\" \"Radarr\" \"Prowlarr\" \"Jellyseerr\" \"NetData\" \"Exit\"; do
        case \$service in
          \"Jellyfin\") xdg-open http://localhost:$JELLYFIN_PORT;;
          \"Sonarr\") xdg-open http://localhost:$SONARR_PORT;;
          \"Radarr\") xdg-open http://localhost:$RADARR_PORT;;
          \"Prowlarr\") xdg-open http://localhost:$PROWLARR_PORT;;
          \"Jellyseerr\") xdg-open http://localhost:$JELLYSEERR_PORT;;
          \"NetData\") xdg-open http://localhost:$NETDATA_PORT;;
          \"Exit\") break;;
          *) echo \"Invalid option.\";;
        esac
      done
      ;;
    \"Restart Service\") read -p \"Service name: \" sname; systemctl restart \"\$sname\";;
    \"Check Services\") echo \"Checking services...\"; systemctl list-units --type=service --state=running;;
    \"Exit\") break;;
    *) echo \"Invalid option.\";;
  esac
done
EOF"

# Make the script executable
run_command "chmod +x /usr/local/bin/media-setup"

### 17. Final Steps ###
# Final steps to complete the setup.
# Optionally prompt the user to reboot the system to apply all changes.

echo "Media server setup complete! Run 'media-setup' to manage services."
if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] Skipping reboot prompt."
else
  read -p "Do you want to reboot now? (yes/no): " reboot_confirm
  if [[ "$reboot_confirm" == "yes" ]]; then
    reboot
  else
    echo "Reboot skipped. Please remember to reboot the server later."
  fi
fi