# jenkins-lab-infra

Lab CI/CD Jenkins self-hosted di AWS (ap-southeast-1) dengan Terraform dan User Data (tanpa Ansible).
Aplikasi: https://github.com/kanjeeng/portofolio-tailwind-css (hanya di-clone, tidak diubah).

## Arsitektur singkat
- VPC 10.2.0.0/16, subnet publik 10.2.1.0/24
- Server 1 (10.2.1.10): Jenkins LTS :8080, Docker, Trivy (dipasang User Data)
- Server 2 (10.2.1.20): Docker, aplikasi :3000, SSH hanya dari Server 1 (user `deploy`)
- Akses admin hanya dari IP pengembang /32. Jalur darurat: AWS SSM Session Manager.

## Struktur
- `terraform/jenkins-lab/` : VPC, SG, EC2, IAM, EIP + `scripts/user-data-*.sh`
- `Jenkinsfile` : pipeline berparameter (Checkout, Lint, Build, Scan, Push, Approval, Deploy, Health Check)
- `jenkins/freestyle-build.sh` : skrip Execute shell job Freestyle
- `jenkins/plugins.txt` : daftar plugin (referensi)

## Perintah cepat
```bash
# 1. Kunci SSH
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/jenkins_lab_admin -C admin-jenkins-lab
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/jenkins_lab_deploy -N "" -C jenkins-deploy

# 2. Terraform
cd terraform/jenkins-lab
cp terraform.tfvars.example terraform.tfvars   # isi developer_ip_cidr (IP publik /32)
terraform init && terraform fmt -recursive && terraform validate
terraform plan -out=tfplan && terraform apply tfplan
terraform output

# 3. Setelah kedua server selesai bootstrap (cloud-init status --wait), di Server 1:
sudo /usr/local/bin/register-app-hostkey          # rekam host key Server 2
sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# 4. Lanjutkan setup Jenkins lewat GUI (lihat BAB II)

# 5. Bersihkan
terraform destroy
```

## Keamanan
Jangan commit: `terraform.tfvars`, `*.tfstate*`, `tfplan`, kunci SSH.
Rahasia (token Docker Hub, webhook Discord, API key) hanya diketik ke Jenkins Credentials.
Jenkins berjalan pada HTTP 8080 yang dibatasi ke IP pengembang; HTTPS (Nginx) adalah eksplorasi opsional.
