### Configuration ###

# Directories
DRIVES=("/dev/sdX" "/dev/sdY" "/dev/sdZ")  # Replace with your drives
MOUNT_POINTS=("/mnt/disk1" "/mnt/disk2" "/mnt/disk3")  # Individual mount points
MERGERFS_POOL="/mnt/storage"  # MergerFS pool mount point
TRANSCODE_DIR="$MERGERFS_POOL/transcode"  # Transcode directory
CONFIG_DIR="$MERGERFS_POOL/configs"  # Config directory
DOWNLOADS_DIR="$MERGERFS_POOL/downloads"  # Downloads directory
MOVIES_DIR="$MERGERFS_POOL/movies"  # Movies directory
SERIES_DIR="$MERGERFS_POOL/series"  # Series directory
LOGS_DIR="$MERGERFS_POOL/logs"  # Logs directory
TMP_DIR="$MERGERFS_POOL/tmp"  # Temporary directory

# Server and NGINX
SERVER_NAME="yourserver.ddns.net"  # Replace with your server name
NGINX_NAME="yourserver"  # NGINX server name
NGINX_SERVICES=("jellyfin" "jellyseerr" "netdata")  # Services to enable in NGINX

# User and Group
USER="root"  # Replace with the user to run services as
GROUP="root"  # Replace with the group to run services as

# Service Ports
JELLYFIN_PORT=8096
SONARR_PORT=8989
RADARR_PORT=7878
PROWLARR_PORT=9696
JELLYSEERR_PORT=5055
FLARESOLVERR_PORT=8191
NETDATA_PORT=19999

# Feature Toggles
ENABLE_JELLYFIN=true
ENABLE_TDARR=true
ENABLE_SONARR=true
ENABLE_RADARR=true
ENABLE_PROWLARR=true
ENABLE_JELLYSEERR=true
ENABLE_FLARESOLVERR=true
ENABLE_NETDATA=true
ENABLE_WATCHTOWER=true
ENABLE_RECYCLARR=true
ENABLE_FORMAT_AND_PARTITIONING=true
ENABLE_DDNS=true  # Toggle for DDNS setup
INSTALL_TDARR_ONEFLOW=true  # Toggle for Tdarr OneFlow installation

# Health Checks
ENABLE_JELLYFIN_HEALTHCHECK=true
ENABLE_TDARR_HEALTHCHECK=true
ENABLE_SONARR_HEALTHCHECK=true
ENABLE_RADARR_HEALTHCHECK=true
ENABLE_PROWLARR_HEALTHCHECK=true
ENABLE_JELLYSEERR_HEALTHCHECK=true
ENABLE_FLARESOLVERR_HEALTHCHECK=true
ENABLE_NETDATA_HEALTHCHECK=true

# Miscellaneous
DDNS_SERVER="dynupdate.no-ip.com"
DDNS_LOGIN="your_ddns_login"  # Replace with your DDNS login
DDNS_PASSWORD="your_ddns_password"  # Replace with your DDNS password
DAYS_TO_KEEP_LOGS="7"
CERTBOT_EMAIL="youremail@example.com"  # Replace with your email for Certbot notifications
EMAIL="$CERTBOT_EMAIL"  # Alias for Certbot email
MAX_LOG_SIZE="10"  # Maximum log size in MB
