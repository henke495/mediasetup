# Media Server Setup Script

This repository contains a script to set up a media server with various components, including Jellyfin, Tdarr, Sonarr, Radarr, and more. It also configures a reverse proxy using NGINX and provides a terminal menu for managing services.

## Features

- Formats and pools drives using MergerFS
- Installs and configures:
  - Jellyfin
  - Tdarr
  - Sonarr
  - Radarr
  - Prowlarr
  - Jellyseerr
  - Flaresolverr
  - Watchtower
  - NetData
- Sets up a reverse proxy with NGINX
- Configures dynamic DNS with ddclient
- Enables HTTPS using Certbot
- Provides health checks for services
- Creates a terminal menu for managing services

## Prerequisites

- Ubuntu-based distribution (e.g., Ubuntu, Linux Mint)
- Root privileges
- Internet connection

## Setup Instructions

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/henke495/mediasetup.git
   cd mediasetup
   ```

2. **Configure `config.sh`**:
   ```bash
   nano config.sh
   ```
   Update the configuration file with your specific settings.

3. **Run the Setup Script**:
   ```bash
   sudo bash setup.sh
   ```
   Use the `--dry-run` flag to preview changes without applying them:
   ```bash
   sudo bash setup.sh --dry-run
   ```

4. **Reboot the System**:
   After the setup is complete, reboot the system to apply all changes:
   ```bash
   sudo reboot
   ```

## Usage

- Use the terminal menu to manage services:
  ```bash
  media-setup
  ```

- Open the web interfaces for installed services:
  - Jellyfin: `http://<your-server-ip>:8096`
  - Sonarr: `http://<your-server-ip>:8989`
  - Radarr: `http://<your-server-ip>:7878`
  - Prowlarr: `http://<your-server-ip>:9696`
  - Jellyseerr: `http://<your-server-ip>:5055`
  - NetData: `http://<your-server-ip>:19999`

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
