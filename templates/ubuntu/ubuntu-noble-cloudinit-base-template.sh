#!/bin/bash

VMID=10002
STORAGE=local-lvm

VM_NAME="ubuntu-2404-cloudinit-template"
STORAGE="local-lvm"  # Change if you use a different storage (e.g. local-zfs)
# Ubuntu 24.04 full cloud image URL (not the minimal image)
IMAGE_URL="https://cloud-images.ubuntu.com/daily/server/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_PATH="/var/lib/vz/template/iso/$(basename ${IMAGE_URL})"
CI_USER="ubuntu"
CI_PASSWORD="$(openssl passwd -6 ubuntu)"

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

# Create the new VM in UEFI mode with OVMF (adjust memory, cores, etc. as needed)
echo "Creating VM ${VM_NAME} with VMID ${VMID}..."
qm create ${VMID} \
  --name "${VM_NAME}" \
  --ostype l26 \
  --memory 2048 \
  --cores 2 \
  --agent 1 \
  --bios ovmf --machine q35 --efidisk0 ${STORAGE}:0,pre-enrolled-keys=0 \
  --cpu host --socket 1 --cores 2 \
  --vga serial0 --serial0 socket \
  --net0 virtio,bridge=vmbr0

# Import the downloaded disk image into storage
echo "Importing disk image..."
qm importdisk ${VMID} "${IMAGE_PATH}" ${STORAGE}

# Attach the imported disk as a VirtIO disk on the SCSI controller.
# (Adjust the disk numbering if needed; here we assume it gets imported as disk-1.)
qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-${VMID}-disk-1,discard=on

# Resize the disk by adding 8G
qm resize ${VMID} virtio0 +8G

# Set the boot order so the VM boots from the VirtIO disk.
qm set $VMID --boot order=virtio0

# Attach a Cloud‑Init drive (under UEFI it is recommended to use SCSI)
qm set $VMID --scsi1 $STORAGE:cloudinit

# Create a custom Cloud‑Init snippet
cat << EOF | tee /var/lib/vz/snippets/ubuntu.yaml
#cloud-config
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent htop
    - systemctl enable ssh
    - reboot
EOF

# Apply the Cloud‑Init configuration snippet and additional settings
qm set $VMID --cicustom "vendor=local:snippets/ubuntu.yaml"
qm set $VMID --tags ubuntu-template,noble,cloudinit
qm set ${VMID} --ciuser ${CI_USER} --cipassword "${CI_PASSWORD}"
qm set $VMID --sshkeys ~/ssh.pub
qm set $VMID --ipconfig0 ip=dhcp

# Finally, convert the VM to a template.
echo "Converting VM to template..."
qm template ${VMID}

echo "Template ${VM_NAME} (VMID: ${VMID}) created successfully."