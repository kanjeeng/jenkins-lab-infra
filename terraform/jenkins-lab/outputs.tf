output "jenkins_public_ip" {
  value = aws_eip.jenkins.public_ip
}

output "jenkins_private_ip" {
  value = var.jenkins_private_ip
}

output "app_public_ip" {
  value = aws_eip.app.public_ip
}

output "app_private_ip" {
  value = var.app_private_ip
}

output "jenkins_url" {
  value = "http://${aws_eip.jenkins.public_ip}:8080"
}

output "app_url" {
  value = "http://${aws_eip.app.public_ip}:3000"
}

output "ssh_jenkins" {
  value = "ssh -i ${trimsuffix(pathexpand(var.admin_public_key_path), ".pub")} ubuntu@${aws_eip.jenkins.public_ip}"
}

output "ssh_app_via_jenkins" {
  description = "SSH ke Server 2 melalui Server 1 (ProxyCommand)"
  value       = "ssh -i ${trimsuffix(pathexpand(var.admin_public_key_path), ".pub")} -o ProxyCommand='ssh -i ${trimsuffix(pathexpand(var.admin_public_key_path), ".pub")} -W %h:%p ubuntu@${aws_eip.jenkins.public_ip}' ubuntu@${var.app_private_ip}"
}

output "ssm_jenkins" {
  value = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.aws_region}"
}

output "ssm_app" {
  value = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}
