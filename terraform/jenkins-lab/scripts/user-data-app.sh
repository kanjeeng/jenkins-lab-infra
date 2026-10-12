#!/bin/bash
# User Data Server 2 (App Host). Dijalankan cloud-init satu kali saat EC2 pertama menyala.
# Log: /var/log/user-data.log   Penanda selesai: /var/lib/cloud/instance/user-data-finished
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname ${hostname}

# ---------- Swap ----------
if [ ! -f /swapfile ]; then
  fallocate -l ${swap_size_gb}G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/60-swap.conf
  sysctl -p /etc/sysctl.d/60-swap.conf
fi

# ---------- Paket dasar ----------
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg jq fail2ban python3-systemd unattended-upgrades

install -m 0755 -d /etc/apt/keyrings

# ---------- Docker (repo resmi, HTTPS, signed-by) ----------
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
cat > /etc/docker/daemon.json <<'EOF2'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF2
systemctl enable --now docker
systemctl restart docker

# ---------- User deploy (dipakai Jenkins lewat SSH) ----------
id deploy > /dev/null 2>&1 || useradd -m -s /bin/bash -G docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo 'from="${jenkins_private_ip}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${deploy_public_key}' > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys

# ---------- Hardening dasar ----------
cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF2'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
AllowUsers ubuntu deploy
EOF2
sshd -t && systemctl reload ssh

cat > /etc/fail2ban/jail.local <<'EOF2'
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 10.2.0.0/16

[sshd]
enabled = true
EOF2
systemctl enable --now fail2ban
systemctl restart fail2ban

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF2'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF2

touch /var/lib/cloud/instance/user-data-finished
