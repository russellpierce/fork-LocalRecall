output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_url" {
  description = "URL of the Application Load Balancer"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.localrecall.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.main.name
}

output "efs_file_system_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.localrecall.id
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for ECS logs"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "deployment_instructions" {
  description = "Instructions for deploying a new version"
  value       = <<-EOT
    To deploy a new version:

    1. Build and push your Docker image:
       docker build -t localrecall:latest .
       aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.localrecall.repository_url}
       docker tag localrecall:latest ${aws_ecr_repository.localrecall.repository_url}:latest
       docker push ${aws_ecr_repository.localrecall.repository_url}:latest

    2. Update the ECS service:
       aws ecs update-service --cluster ${aws_ecs_cluster.main.name} --service ${aws_ecs_service.main.name} --force-new-deployment --region ${var.aws_region}

    3. Monitor the deployment:
       aws ecs describe-services --cluster ${aws_ecs_cluster.main.name} --services ${aws_ecs_service.main.name} --region ${var.aws_region}

    4. View logs:
       aws logs tail ${aws_cloudwatch_log_group.ecs.name} --follow --region ${var.aws_region}
  EOT
}
