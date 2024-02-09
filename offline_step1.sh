#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root" >&2
  exit 1
fi

echo 'Ensuring /usr/local/bin is in the PATH for all sessions...'
echo 'export PATH=$PATH:/usr/local/bin' >> /etc/profile.d/custompath.sh

echo "Preparing the environment..."

echo "Removing podman, buildah, and skopeo..."
yum remove -y podman buildah skopeo

#!/bin/bash

# Directory containing the local RPM repository
REPO_DIR="/offline_repo"

# YUM repository configuration file path
REPO_CONF="/etc/yum.repos.d/local.repo"

# Check if the repository directory exists
if [ ! -d "$REPO_DIR" ]; then
    echo "Error: Repository directory '$REPO_DIR' not found."
    exit 1
fi

# Create a YUM repository configuration file
echo "Creating YUM repository configuration file..."
sudo bash -c "cat <<EOF > $REPO_CONF
[local]
name=Local Repository
baseurl=file://$REPO_DIR
enabled=1
gpgcheck=0
EOF
"

sudo sed -i 's/enabled=1/enabled=0/' /etc/yum.repos.d/redhat.repo

# Clean the DNF cache
echo "Cleaning DNF cache..."
dnf clean all

# Regenerate DNF metadata
echo "Regenerating DNF metadata..."
dnf makecache

echo "YUM repository configuration file created at $REPO_CONF"

echo "Installing additional packages..."
yum install -y device-mapper-persistent-data lvm2 nfs-utils containerd.io --allowerasing

echo "Installing Kubernetes components..."
yum install -y  kubelet-1.28.5 kubeadm-1.28.5 kubectl-1.28.5 --disableexcludes=kubernetes



# Disable SELINUX
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config

# Turn off FirewallD
systemctl stop firewalld && systemctl disable firewalld

# Disable SWAP
swapoff -a
sed -e '/swap/s/^/#/g' -i /etc/fstab

# Load network related modules
modprobe overlay
modprobe br_netfilter
modprobe ip_vs
modprobe ip_tables

# Configure sysctl settings for Kubernetes networking
cat <<EOF > /etc/modules-load.d/iptables.conf
ip_tables
EOF

cat <<EOF > /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

echo "Installing nerdctl..."
cp /offline_binaries/nerdctl /usr/local/bin/
chmod +x /usr/local/bin/nerdctl

echo "Installing Containerd from local RPM..."
yum containerd.io-1.6.4-3.1.el8.x86_64.rpm

# Assuming the systemd service file might not be properly linked or recognized
if [ ! -f /etc/systemd/system/containerd.service ]; then
    systemctl link /usr/lib/systemd/system/containerd.service
fi

systemctl daemon-reload

echo "Configuring containerd..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "Restarting and enabling containerd service..."
systemctl restart containerd
systemctl enable containerd

echo "Loading container images into containerd..."
for IMAGE_TAR in /offline_images/*.tar; do
    echo "Loading image from ${IMAGE_TAR}..."
    nerdctl -n k8s.io load -i "${IMAGE_TAR}"
done

echo "Loading container images into containerd..."
for IMAGE_TAR in /offline_cni/*.tar; do
    echo "Loading image from ${IMAGE_TAR}..."
    nerdctl -n k8s.io load -i "${IMAGE_TAR}"
done
# Ensure kubelet is enabled after installation
systemctl enable kubelet

echo "Updating sysctl settings..."
sysctl -p

echo "Setup complete. Please reboot the system."
