#!/bin/bash

# ===== CONFIGURABLE PARAMETERS =====
VMID=10008
VM_NAME="ubuntu-2404-cloudinit-k8s-template"
STORAGE="local-lvm"  # Change if you use a different storage (e.g. local-zfs)
MEMORY=3072          # Memory in MB (3GB default)
SOCKETS=1            # CPU sockets
CORES=2              # CPU cores per socket
DISK_ADDITIONAL_SIZE="+8G"  # Additional disk space to add

# Ubuntu 24.04 full cloud image URL (not the minimal image)
IMAGE_URL="https://cloud-images.ubuntu.com/daily/server/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_PATH="/var/lib/vz/template/iso/$(basename ${IMAGE_URL})"
CI_USER="ubuntu"
CI_PASSWORD="$(openssl passwd -6 ubuntu)"  # For production, use a stronger plaintext password before hashing

echo "ssh-rsa PASTE YOUR PUBLIC KEY HERE" > ssh.pub

# 1. Download the Ubuntu 24.04 Cloud Image (if not already present)
if [ ! -f "${IMAGE_PATH}" ]; then
  echo "Downloading Ubuntu 24.04 Cloud Image..."
  wget -P /var/lib/vz/template/iso/ "${IMAGE_URL}"
else
  echo "Image already exists at ${IMAGE_PATH}"
fi

set -x

# Destroy existing VM with this ID if it exists (ignore errors)
qm destroy $VMID 2>/dev/null || true

# Create the new VM in UEFI mode with OVMF (using configurable parameters)
echo "Creating VM ${VM_NAME} with VMID ${VMID}..."
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

# Import the downloaded disk image into storage
echo "Importing disk image..."
qm importdisk ${VMID} "${IMAGE_PATH}" ${STORAGE}

# Attach the imported disk as a VirtIO disk on the SCSI controller.
# (Adjust the disk numbering if needed; here we assume it gets imported as disk-1.)
qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-${VMID}-disk-1,discard=on

# Resize the disk by adding the configured amount
qm resize ${VMID} virtio0 ${DISK_ADDITIONAL_SIZE}

# Set the boot order so the VM boots from the VirtIO disk.
qm set $VMID --boot order=virtio0

# Attach a Cloud‑Init drive (under UEFI it is recommended to use SCSI)
qm set $VMID --scsi1 $STORAGE:cloudinit

# Create a custom Cloud‑Init snippet that installs Kubernetes tools (version 1.32 series, allowing patch updates) and tailscale.
cat << 'EOF' | tee /var/lib/vz/snippets/ubuntu_k8s.yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg2
  - lsb-release
  - software-properties-common
  - containerd.io
  - qemu-guest-agent
  - htop
write_files:
  - path: /etc/sysctl.d/k8s.conf
    permissions: "0644"
    content: |
      net.bridge.bridge-nf-call-iptables=1
      net.ipv4.ip_forward=1
      net.bridge.bridge-nf-call-ip6tables=1
runcmd:
  # Disable swap (required by Kubernetes)
  - swapoff -a
  #- sed -i '/ swap / s/^/#/' /etc/fstab

  # Load required kernel modules
  - sudo sh -c 'echo "overlay" > /etc/modules-load.d/k8s.conf'
  - sudo sh -c 'echo "br_netfilter" > /etc/modules-load.d/k8s.conf'
  - modprobe overlay
  - modprobe br_netfilter

  # Enable and start QEMU Guest Agent
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

  # Add Docker's GPG key and repository
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update

  # Install containerd and configure it to use systemd cgroups
  - apt-get install -y containerd.io
  - mkdir -p /etc/containerd
  - containerd config default | tee /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  - systemctl restart containerd
  - systemctl enable containerd

  # Add Tailscale repository and install Tailscale (Ubuntu 24.04 - noble)
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
  - apt-get update
  - apt-get install -y tailscale

  # Add Kubernetes apt repository key and repository for Ubuntu 24.04 using the new community-owned repo
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  - apt-get update

  # Install Kubernetes tools (kubelet, kubeadm, kubectl) using version pattern 1.32-*
  - apt-get install -y 'kubelet=1.32.*' 'kubeadm=1.32.*' 'kubectl=1.32.*'
  - apt-mark hold kubelet kubeadm kubectl

  # Enable and start kubelet
  - systemctl enable kubelet
  - systemctl start kubelet

  # (Optional) Bring up Tailscale by uncommenting and providing your auth key:
  #- sudo tailscale up --authkey=

  # Reboot to finalize configuration
  - reboot
EOF

# Apply the Cloud‑Init configuration snippet and additional settings
qm set $VMID --cicustom "vendor=local:snippets/ubuntu_k8s.yaml"
qm set $VMID --tags ubuntu-template,noble,cloudinit,k8s
qm set ${VMID} --ciuser ${CI_USER} --cipassword "${CI_PASSWORD}"
qm set $VMID --sshkeys ~/ssh.pub
qm set $VMID --ipconfig0 ip=dhcp

# Finally, convert the VM to a template.
echo "Converting VM to template..."
qm template ${VMID}

echo "Template ${VM_NAME} (VMID: ${VMID}) created successfully."
echo "Memory: ${MEMORY}MB, CPUs: ${SOCKETS} socket(s) with ${CORES} core(s) each"