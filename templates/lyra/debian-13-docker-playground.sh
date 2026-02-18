#!/bin/bash

# ===== DOCKER PLAYGROUND PROXMOX TEMPLATE =====
# Based on original script by Ali Shaikh <alishaikh.me>
# This script creates a Debian 13 VM template with Docker and OpenClaw pre-installed
#
# Repository: Ali-Shaikh/proxmox-toolbox
#
# Features:
# - All original features from Ali's script
# - Docker CE & Docker Compose pre-installed
# - debian user added to docker group
#
# ===== CONFIGURABLE PARAMETERS =====

VMID=10013
VM_NAME="debian-13-docker-playground"
STORAGE="local-lvm"
MEMORY=4096
SOCKETS=1
CORES=2
DISK_ADDITIONAL_SIZE="+15G"

IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/$(basename ${IMAGE_URL})"

CI_USER="debian"
CI_PASSWORD="$(openssl passwd -6 debian)"

# Public Key - REPLACE THIS with your own SSH public key
SSH_PUB_KEY="REPLACE_WITH_YOUR_SSH_KEY"

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

# Create Cloud-Init configuration
cat << 'CLOUDCONFIG' | tee /var/lib/vz/snippets/debian13_docker_playground.yaml
#cloud-config

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - build-essential
  - ca-certificates
  - gnupg
  - qemu-guest-agent
  - htop
  - vim
  - tmux
  - jq
  - cron

write_files:
  - path: /etc/profile.d/cloud-init-status.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      BLUE='\033[0;34m'
      NC='\033[0m'

      if cloud-init status 2>/dev/null | grep -q "running"; then
        echo -e "${YELLOW}System is still initialising...${NC}"
        echo "Monitor: sudo tail -f /var/log/cloud-init-output.log"
      elif [ -f /root/.docker-ready ]; then
        echo -e "${GREEN}Docker Playground is READY!${NC}"
        echo "Run 'docker ps' or 'setup-openclaw.sh' to start."
      fi

  - path: /root/install-docker.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      exec > /var/log/docker-install.log 2>&1
      
      echo "=== Docker Playground Installation Started ==="
      
      # Install Docker
      echo "Installing Docker..."
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      usermod -aG docker debian

      # Install Node.js 24
      echo "Installing Node.js 24..."
      curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
      apt-get install -y nodejs
      npm install -g pnpm openclaw@latest

      # Mark ready
      touch /root/.docker-ready
      echo "=== Installation Complete ==="

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - chmod +x /root/install-docker.sh
  - /root/install-docker.sh

CLOUDCONFIG

# Apply Cloud-Init configuration
qm set $VMID --cicustom "vendor=local:snippets/debian13_docker_playground.yaml"
qm set $VMID --tags debian-template,docker-playground,docker,openclaw
qm set ${VMID} --ciuser ${CI_USER} --cipassword "${CI_PASSWORD}"
echo "${SSH_PUB_KEY}" > /tmp/playground_keys.pub
qm set $VMID --sshkeys /tmp/playground_keys.pub
qm set $VMID --ipconfig0 ip=dhcp

# Convert to template
qm template ${VMID}

echo "Template ${VMID} (${VM_NAME}) created successfully!"
