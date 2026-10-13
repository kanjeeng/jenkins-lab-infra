#!/bin/bash
# User Data Server 1 (Jenkins). Dijalankan cloud-init satu kali saat EC2 pertama menyala.
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
apt-get install -y ca-certificates curl gnupg git jq unzip fontconfig \
  openjdk-21-jre-headless fail2ban python3-systemd unattended-upgrades

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

# ---------- Jenkins LTS (repo resmi, HTTPS, signed-by, GPG Keyring 2026) ----------
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | gpg --dearmor --yes -o /usr/share/keyrings/jenkins-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y
apt-get install -y jenkins
usermod -aG docker jenkins
systemctl enable jenkins
systemctl restart jenkins

# ---------- Trivy (pemindai image resmi dengan dearmor) ----------
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor --yes -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list
apt-get update -y
apt-get install -y trivy

# ---------- Hardening dasar ----------
cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF2'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
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

# ---------- Skrip bantu: rekam host key Server 2 untuk user jenkins ----------
# Dijalankan MANUAL sekali setelah Server 2 siap (verifikasi host key, bukan allowAnyHosts).
cat > /usr/local/bin/register-app-hostkey <<'EOF2'
#!/bin/bash
set -euo pipefail
APP_IP="$${1:-${app_private_ip}}"
install -d -m 700 -o jenkins -g jenkins /var/lib/jenkins/.ssh
TMP="$(mktemp)"
ssh-keyscan -t ed25519 "$APP_IP" 2> /dev/null > "$TMP"
test -s "$TMP"
cat "$TMP" >> /var/lib/jenkins/.ssh/known_hosts
chown jenkins:jenkins /var/lib/jenkins/.ssh/known_hosts
chmod 644 /var/lib/jenkins/.ssh/known_hosts
rm -f "$TMP"
echo "Host key $APP_IP terekam:"
ssh-keygen -lf /var/lib/jenkins/.ssh/known_hosts
EOF2
chmod 755 /usr/local/bin/register-app-hostkey

touch /var/lib/cloud/instance/user-data-finished
