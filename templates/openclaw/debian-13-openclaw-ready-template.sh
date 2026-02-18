#!/bin/bash

# ===== PRODUCTION-READY OPENCLAW PROXMOX TEMPLATE =====
# This script creates a Debian 13 VM template with OpenClaw pre-installed
#
# Author: Ali Shaikh <alishaikh.me>
#
# Features:
# - Cloud-init progress indication
# - Login warnings during initialisation
# - Automatic pnpm setup
# - Status check commands
# - Access info helper command
# - Proper error handling
#
# ===== CONFIGURABLE PARAMETERS =====

VMID=10010
VM_NAME="debian-13-openclaw-ready-template"
STORAGE="local-lvm"
MEMORY=4096
SOCKETS=1
CORES=2
DISK_ADDITIONAL_SIZE="+15G"

IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/$(basename ${IMAGE_URL})"

CI_USER="debian"
CI_PASSWORD="$(openssl passwd -6 debian)" # For production, use a stronger password

# Replace with your actual SSH public key
echo "ssh-rsa " > ~/ssh.pub

# Download Debian 13 Cloud Image
if [ ! -f "${IMAGE_PATH}" ]; then
  echo "Downloading Debian 13 Cloud Image..."
  wget -P /var/lib/vz/template/iso/ "${IMAGE_URL}"
else
  echo "Image already exists at ${IMAGE_PATH}"
fi

set -x

# Destroy existing VM if it exists
qm destroy $VMID 2>/dev/null || true

# Create VM
qm create ${VMID} \
  --name "${VM_NAME}" \
  --ostype l26 \
  --memory ${MEMORY} \
  --cores ${CORES} \
  --agent 1 \
  --bios ovmf --machine q35 --efidisk0 ${STORAGE}:0,pre-enrolled-keys=0 \
  --cpu host --socket ${SOCKETS} --cores ${CORES} \
  --vga serial0 --serial0 socket \
  --net0 virtio,bridge=vmbr0

# Import disk
qm importdisk ${VMID} "${IMAGE_PATH}" ${STORAGE}
UNUSED_DISK=$(qm config $VMID | grep -o 'unused[0-9]\+:[^ ]\+' | head -n 1 | cut -d':' -f2-)
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $UNUSED_DISK,discard=on
qm resize ${VMID} scsi0 ${DISK_ADDITIONAL_SIZE}
qm set $VMID --boot order=scsi0
qm set $VMID --scsi1 $STORAGE:cloudinit

# Create snippets directory
mkdir -p /var/lib/vz/snippets/

# Create Cloud-Init configuration with proper YAML formatting
cat << 'CLOUDCONFIG' | tee /var/lib/vz/snippets/debian13_openclaw_ready.yaml
#cloud-config

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - build-essential
  - procps
  - file
  - ca-certificates
  - gnupg
  - qemu-guest-agent
  - htop
  - vim
  - tmux
  - jq
  - cron

write_files:
  # Login status checker - runs on every login to show progress
  - path: /etc/profile.d/cloud-init-status.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      # Check cloud-init and installation status on login

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      BLUE='\033[0;34m'
      NC='\033[0m' # No Color

      # Check if cloud-init is still running
      if cloud-init status 2>/dev/null | grep -q "running"; then
        echo ""
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}  SYSTEM INITIALISATION IN PROGRESS${NC}"
        echo -e "${YELLOW}========================================${NC}"
        echo ""
        echo -e "${BLUE}Cloud-init is still running. Please wait...${NC}"
        echo ""
        echo "Monitor progress:"
        echo "  sudo tail -f /var/log/cloud-init-output.log"
        echo "  sudo tail -f /var/log/openclaw-install.log"
        echo ""
        echo "Check status:"
        echo "  cloud-init status"
        echo "  cat /var/run/openclaw-install-progress"
        echo ""
        echo -e "${YELLOW}Some commands may not be available yet!${NC}"
        echo ""
      elif [ -f /var/run/openclaw-install-progress ]; then
        PROGRESS=$(cat /var/run/openclaw-install-progress 2>/dev/null)
        if [ "$PROGRESS" != "COMPLETE" ]; then
          echo ""
          echo -e "${YELLOW}Installation in progress: $PROGRESS${NC}"
          echo "Run: sudo tail -f /var/log/openclaw-install.log"
          echo ""
        fi
      elif [ -f /root/.openclaw-ready ]; then
        # Only show ready message once per session
        if [ -z "$OPENCLAW_READY_SHOWN" ]; then
          echo ""
          echo -e "${GREEN}System is ready! Run: setup-openclaw.sh${NC}"
          echo ""
          export OPENCLAW_READY_SHOWN=1
        fi
      fi

  - path: /usr/local/bin/openclaw-access-info
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      echo "==========================================="
      echo "OpenClaw Access Information"
      echo "==========================================="
      echo ""
      echo "Tailscale Serve URL:"
      tailscale serve status 2>/dev/null | grep -o 'https://[^ ]*' || echo "  Not configured - run: openclaw onboard --install-daemon"
      echo ""
      if [ -f ~/.openclaw/openclaw.json ]; then
        echo "Gateway Token:"
        cat ~/.openclaw/openclaw.json | jq -r '.gateway.auth.token' 2>/dev/null || echo "  Not found"
        echo ""
        echo "Allow Tailscale Auth:"
        cat ~/.openclaw/openclaw.json | jq -r '.gateway.auth.allowTailscale' 2>/dev/null || echo "  Not configured"
      else
        echo "OpenClaw not configured yet"
        echo "Run: openclaw onboard --install-daemon"
      fi
      echo "==========================================="

  - path: /usr/local/bin/setup-openclaw.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      echo "======================================"
      echo "OpenClaw Setup Helper"
      echo "======================================"
      echo ""
      echo "Installed versions:"
      echo "  Node.js: $(node --version 2>/dev/null || echo 'Not found')"
      echo "  npm: $(npm --version 2>/dev/null || echo 'Not found')"
      echo "  pnpm: $(pnpm --version 2>/dev/null || echo 'Not installed')"
      echo "  OpenClaw: $(openclaw --version 2>/dev/null || echo 'Not installed - run: npm install -g openclaw@latest')"
      echo "  Tailscale: $(tailscale version 2>/dev/null || echo 'Not found')"
      echo "  Homebrew: $(brew --version 2>/dev/null | head -n1 || echo 'Not found - source ~/.bashrc first')"
      echo ""
      echo "Quick Start Guide:"
      echo "=================="
      echo ""
      echo "1. Connect to Tailscale:"
      echo "   Get auth key: https://login.tailscale.com/admin/settings/keys"
      echo "   sudo tailscale up --authkey=tskey-auth-YOUR_KEY"
      echo ""
      echo "2. Configure pnpm (required for skills):"
      echo "   pnpm setup && source ~/.bashrc"
      echo ""
      echo "3. Configure OpenClaw:"
      echo "   openclaw onboard --install-daemon"
      echo ""
      echo "   Configuration choices:"
      echo "   - Setup: Local gateway (this machine)"
      echo "   - Bind: Loopback (127.0.0.1) <- REQUIRED"
      echo "   - Auth: Token (Recommended)"
      echo "   - Tailscale: Serve (for HTTPS)"
      echo ""
      echo "4. Get access info:"
      echo "   openclaw-access-info"
      echo ""
      echo "5. Verify:"
      echo "   openclaw status"
      echo "   openclaw health"
      echo "   tailscale serve status"
      echo ""
      echo "Docs: https://docs.openclaw.ai"
      echo ""

  # Progress checker command
  - path: /usr/local/bin/check-install-status
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      echo "========================================"
      echo "Installation Status Check"
      echo "========================================"
      echo ""

      # Cloud-init status
      echo "Cloud-init status:"
      cloud-init status 2>/dev/null || echo "  Unable to check"
      echo ""

      # Progress file (cleared after reboot, so may not exist)
      if [ -f /var/run/openclaw-install-progress ]; then
        echo "Current step: $(cat /var/run/openclaw-install-progress)"
      fi

      # Ready marker (use sudo to check /root)
      if sudo test -f /root/.openclaw-ready 2>/dev/null; then
        echo "Status: READY"
      else
        echo "Status: IN PROGRESS (or checking permissions...)"
      fi
      echo ""

      # Installed versions (use sudo to read /root)
      if sudo test -f /root/install-versions.txt 2>/dev/null; then
        echo "Installed versions:"
        sudo cat /root/install-versions.txt | sed 's/^/  /'
      fi
      echo ""

      echo "Logs:"
      echo "  sudo tail -f /var/log/openclaw-install.log"

  - path: /root/install-openclaw.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      # Don't use set -e - we want to continue even if some commands fail
      exec > /var/log/openclaw-install.log 2>&1

      # Progress update function
      update_progress() {
        echo "$1" > /var/run/openclaw-install-progress
        echo ">>> PROGRESS: $1"
      }

      echo "=== OpenClaw Installation Started at $(date) ==="
      update_progress "Starting installation..."

      # Install Tailscale
      update_progress "Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
      if command -v tailscale &> /dev/null; then
        echo "Tailscale version: $(tailscale version)"
      else
        echo "WARNING: Tailscale installation may have failed"
      fi

      # Install Node.js 24
      update_progress "Installing Node.js 24..."
      curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
      apt-get install -y nodejs
      echo "Node.js version: $(node --version)"
      echo "npm version: $(npm --version)"

      # Install pnpm globally
      update_progress "Installing pnpm..."
      npm install -g pnpm@latest
      echo "pnpm version: $(pnpm --version)"

      # Setup pnpm global bin directory (required for OpenClaw skills)
      pnpm setup
      source /root/.bashrc 2>/dev/null || true
      # Also setup for debian user
      sudo -u debian bash -c 'pnpm setup' 2>/dev/null || true

      # Install OpenClaw via npm
      update_progress "Installing OpenClaw..."
      npm install -g openclaw@latest

      # Verify installation and add to PATH if needed
      if command -v openclaw &> /dev/null; then
        echo "OpenClaw version: $(openclaw --version)"
      else
        echo "OpenClaw not in PATH, checking npm global bin..."
        NPM_BIN=$(npm bin -g)
        if [ -f "$NPM_BIN/openclaw" ]; then
          echo "Found at $NPM_BIN/openclaw, creating symlink..."
          ln -sf "$NPM_BIN/openclaw" /usr/local/bin/openclaw
          echo "OpenClaw version: $(openclaw --version)"
        else
          echo "ERROR: OpenClaw installation failed"
          echo "NPM global bin: $NPM_BIN"
          ls -la "$NPM_BIN/" 2>/dev/null || echo "Cannot list npm bin directory"
        fi
      fi

      # Install Homebrew for debian user (for plugins)
      update_progress "Installing Homebrew (this may take a while)..."
      # Create the debian user's home if it doesn't exist
      mkdir -p /home/debian
      chown debian:debian /home/debian

      # Install Homebrew as debian user
      sudo -u debian bash -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' || {
        echo "WARNING: Homebrew installation failed"
      }

      # Add Homebrew to debian user's PATH
      if [ -d "/home/linuxbrew/.linuxbrew" ]; then
        sudo -u debian bash -c 'echo "# Homebrew" >> ~/.bashrc'
        sudo -u debian bash -c 'echo "eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"" >> ~/.bashrc'
        echo "Homebrew installed successfully"
      else
        echo "WARNING: Homebrew directory not found after installation"
      fi

      update_progress "Finalising..."

      echo "=== Installation Complete at $(date) ==="
      echo "Node.js: $(node --version 2>/dev/null || echo 'FAILED')" > /root/install-versions.txt
      echo "npm: $(npm --version 2>/dev/null || echo 'FAILED')" >> /root/install-versions.txt
      echo "pnpm: $(pnpm --version 2>/dev/null || echo 'FAILED')" >> /root/install-versions.txt
      echo "OpenClaw: $(openclaw --version 2>/dev/null || echo 'FAILED')" >> /root/install-versions.txt
      echo "Tailscale: $(tailscale version 2>/dev/null || echo 'FAILED')" >> /root/install-versions.txt
      echo "Homebrew: $(sudo -u debian /home/linuxbrew/.linuxbrew/bin/brew --version 2>/dev/null | head -n1 || echo 'FAILED')" >> /root/install-versions.txt

      # Mark installation as complete
      update_progress "COMPLETE"
      touch /root/.openclaw-ready

      echo ""
      echo "Check /root/install-versions.txt for results"

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - echo "INITIALISING" > /var/run/openclaw-install-progress
  - chmod +x /root/install-openclaw.sh
  - /root/install-openclaw.sh
  - chown debian:debian /usr/local/bin/setup-openclaw.sh
  - |
    cat >> /etc/motd << 'MOTD'

    ========================================
    OpenClaw Ready Template
    ========================================
    Created by Ali Shaikh
    https://alishaikh.me

    Pre-installed (globally):
      - Node.js 24 (NodeSource)
      - pnpm (latest)
      - OpenClaw CLI
      - Tailscale (official)
      - Homebrew (for plugins)

    Check installation: cat /root/install-versions.txt
    Check status: check-install-status
    Setup guide: setup-openclaw.sh
    Access info: openclaw-access-info (after configuration)

    MOTD
  - apt-get clean
  - apt-get autoremove -y

power_state:
  mode: reboot
  message: "Rebooting after OpenClaw installation"
  timeout: 30
  condition: True

CLOUDCONFIG

# Apply Cloud-Init configuration
qm set $VMID --cicustom "vendor=local:snippets/debian13_openclaw_ready.yaml"
qm set $VMID --tags debian-template,openclaw-ready,nodejs24,production
qm set ${VMID} --ciuser ${CI_USER} --cipassword "${CI_PASSWORD}"
qm set $VMID --sshkeys ~/ssh.pub
qm set $VMID --ipconfig0 ip=dhcp

# Convert to template
qm template ${VMID}

echo ""
echo "=========================================="
echo "PRODUCTION TEMPLATE CREATED SUCCESSFULLY"
echo "=========================================="
echo "Template ID: ${VMID}"
echo "Template Name: ${VM_NAME}"
echo ""
echo "Globally installed:"
echo "  - Node.js 24 (NodeSource)"
echo "  - pnpm (latest)"
echo "  - OpenClaw CLI"
echo "  - Tailscale (official)"
echo "  - Homebrew (for plugins)"
echo ""
echo "DEPLOYMENT:"
echo "  qm clone ${VMID} 201 --name openclaw-prod --full"
echo "  qm start 201"
echo ""
echo "IMPORTANT: Wait 5-7 minutes for installation to complete"
echo ""
echo "CHECK INSTALLATION STATUS:"
echo "  ssh debian@<vm-ip>"
echo "  check-install-status        # Quick status check"
echo "  tail -f /var/log/openclaw-install.log"
echo "  cat /root/install-versions.txt"
echo ""
