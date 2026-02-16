#!/bin/bash

# ===== LYRA DOCKER PLAYGROUND PROXMOX TEMPLATE =====
# Based on original script by Ali Shaikh <alishaikh.me>
# This script creates a Debian 13 VM template with Docker and OpenClaw pre-installed
#
# Author: Lyra (AI Assistant)
# Repository: Ali-Shaikh/proxmox-toolbox
#
# Features:
# - All original features from Ali's script
# - Docker CE & Docker Compose pre-installed
# - debian user added to docker group
# - Lyra's SSH key injected for access
#
# ===== CONFIGURABLE PARAMETERS =====

VMID=10013
VM_NAME="debian-13-lyra-docker-playground"
STORAGE="local-lvm"
MEMORY=4096
SOCKETS=1
CORES=2
DISK_ADDITIONAL_SIZE="+15G"

IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMAGE_PATH="/var/lib/vz/template/iso/$(basename ${IMAGE_URL})"

CI_USER="debian"
CI_PASSWORD="$(openssl passwd -6 debian)"

# Lyra's Public Key (automatically injected)
LYRA_PUB_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCOee87RNJBS0EAndygEwCpYZnBu4t5wNmNrG7xfvub5jhH+in7qnZfO0t3FHDkF2Wh0raDpQR05b4BroYQHXBukEMkyGgxcruipzhkSUguTjGmpC4LT1j/QdCpIXAkcOFFpgNY6U39Ra97Cb0RbN921QnKPMyArqbUJO2GLaQcy74ovUEeoyhGJgLLgvnWwCRTqYbwXskU24Bj6S1+89znDwP+0mofDliqIEchmGNvt/RE0VnSimqu9OFRupnmMuRlGgADaba8q5lfXCjkgr/qe6tSVPoxkzax0kS4EoiFtjFqQMIDPiPZ3YdST/r2qSrfgPuolCJPzvfNA5xBZh3U9g3s5iyPOjd4UKa/Y9+Hlgmm2I41iVFmu/gpBxGFtLNbNVzXz/4O1SlJubIReroG4Psa4Olu3Z6bgmGa0DmpvflEvqPqKVGJZNRjr1KZtnk93JLrEdn4MigitVvWeFY9DrYCfzp0Efrf4JtjuHzfeGtOzEKzZbgwEQbPsPitItgY6ud4BM3f2zOCwnlLk641yJALecyVTi3nnQKrRWeV0JvNK2QH8bnMpfuy92JyY2ZcElZX9zRRx6SMSbexTtQTXesid7o9nhjIQ4ZRzwWKbc0+wMDvLPwYydvHArGOuzJ8oGJGGKY1mdQW6v4GOoZr8yMVGGjhA1JXQvIV9JaoVQ== debian@openclaw-host1"

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
qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-${VMID}-disk-1,discard=on
qm resize ${VMID} virtio0 ${DISK_ADDITIONAL_SIZE}
qm set $VMID --boot order=virtio0
qm set $VMID --scsi1 $STORAGE:cloudinit

# Create snippets directory
mkdir -p /var/lib/vz/snippets/

# Create Cloud-Init configuration
cat << 'CLOUDCONFIG' | tee /var/lib/vz/snippets/debian13_lyra_docker.yaml
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
      elif [ -f /root/.lyra-ready ]; then
        echo -e "${GREEN}Lyra Playground is READY!${NC}"
        echo "Run 'docker ps' or 'setup-openclaw.sh' to start."
      fi

  - path: /root/install-lyra.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      exec > /var/log/lyra-install.log 2>&1
      
      echo "=== Lyra Playground Installation Started ==="
      
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
      touch /root/.lyra-ready
      echo "=== Installation Complete ==="

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - chmod +x /root/install-lyra.sh
  - /root/install-lyra.sh

CLOUDCONFIG

# Apply Cloud-Init configuration
qm set $VMID --cicustom "vendor=local:snippets/debian13_lyra_docker.yaml"
qm set $VMID --tags debian-template,lyra-playground,docker,openclaw
qm set ${VMID} --ciuser ${CI_USER} --cipassword "${CI_PASSWORD}"
echo "${LYRA_PUB_KEY}" > /tmp/lyra_keys.pub
# Note: You might want to append your own keys here as well
qm set $VMID --sshkeys /tmp/lyra_keys.pub
qm set $VMID --ipconfig0 ip=dhcp

# Convert to template
qm template ${VMID}

echo "Template ${VMID} (${VM_NAME}) created successfully!"
