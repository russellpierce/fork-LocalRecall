# Terraform Configuration for LocalRecall on AWS Fargate

This Terraform configuration deploys LocalRecall on AWS Fargate with EFS for persistent storage and Application Load Balancer for traffic distribution.

## Architecture

- **ECS Fargate**: Serverless container platform
- **Amazon EFS**: Persistent file storage for vector database and assets
- **Application Load Balancer**: HTTP(S) load balancing
- **Auto Scaling**: Scale from 0 to 10 tasks based on request count
- **CloudWatch**: Centralized logging

## Prerequisites

1. **AWS CLI** configured with credentials
2. **Terraform** >= 1.0
3. **Docker** for building images
4. **LocalAI** instance (or OpenAI API key)

## Quick Start

### 1. Initialize Terraform

```bash
cd terraform
terraform init
```

### 2. Configure Variables

Create `terraform.tfvars`:

```hcl
aws_region         = "us-east-1"
project_name       = "localrecall"
openai_base_url    = "http://your-localai-instance:8080"
openai_api_key     = "your-api-key"
embedding_model    = "granite-embedding-107m-multilingual"

# Scale-to-zero configuration
min_capacity       = 0
max_capacity       = 10
initial_desired_count = 1

# Resource sizing
task_cpu           = "512"   # 0.5 vCPU
task_memory        = "1024"  # 1 GB

# Networking (optional - uses defaults if not specified)
# vpc_cidr           = "10.0.0.0/16"
# availability_zones = ["us-east-1a", "us-east-1b"]
```

### 3. Plan the Deployment

```bash
terraform plan
```

Review the resources that will be created:
- VPC with public/private subnets
- EFS file system with access points
- ECS cluster and Fargate service
- Application Load Balancer
- Security groups
- IAM roles
- CloudWatch log groups

### 4. Deploy Infrastructure

```bash
terraform apply
```

Type `yes` to confirm. Deployment takes about 5-10 minutes.

### 5. Build and Push Docker Image

After infrastructure is created, get the ECR repository URL:

```bash
ECR_URL=$(terraform output -raw ecr_repository_url)
AWS_REGION=$(terraform output -raw aws_region)
```

Build and push the image:

```bash
# From the project root directory
cd ..

# Build the image
docker build -t localrecall:latest .

# Authenticate to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $ECR_URL

# Tag and push
docker tag localrecall:latest $ECR_URL:latest
docker push $ECR_URL:latest
```

### 6. Update ECS Service

After pushing the image, update the service:

```bash
cd terraform
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)

aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --force-new-deployment \
  --region $AWS_REGION
```

### 7. Access the Application

Get the ALB URL:

```bash
terraform output alb_url
```

Test the deployment:

```bash
ALB_URL=$(terraform output -raw alb_url)

# Health check
curl $ALB_URL/health

# Create a collection
curl -X POST $ALB_URL/api/collections \
  -H "Content-Type: application/json" \
  -d '{"name":"test"}'

# List collections
curl $ALB_URL/api/collections
```

## Cost Estimation

Based on default configuration (us-east-1):

| Resource | Monthly Cost (approx) |
|----------|----------------------|
| Fargate (4 hours/day) | $4.80 |
| EFS (10 GB) | $3.00 |
| ALB | $16.00 |
| NAT Gateway | $32.00 |
| **Total** | **~$56/month** |

### Cost Optimization Tips

1. **Remove NAT Gateway** if LocalAI is in the same VPC (saves $32/month)
2. **Use Fargate Spot** for 70% discount (add to task definition)
3. **Reduce min_capacity to 0** for true scale-to-zero
4. **Enable EFS Infrequent Access** for old data

## Monitoring

### View Logs

```bash
aws logs tail /ecs/localrecall --follow --region us-east-1
```

### Check Service Status

```bash
aws ecs describe-services \
  --cluster localrecall-cluster \
  --services localrecall-service \
  --region us-east-1
```

### Monitor Auto Scaling

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/localrecall-cluster/localrecall-service \
  --region us-east-1
```

### CloudWatch Metrics

View metrics in AWS Console:
- ECS → Clusters → localrecall-cluster → Metrics
- EFS → File systems → localrecall-efs → Monitoring
- EC2 → Load Balancers → localrecall-alb → Monitoring

## Updating the Deployment

### Update Application Code

```bash
# Build new image
docker build -t localrecall:latest .

# Push to ECR
ECR_URL=$(terraform output -raw ecr_repository_url)
docker tag localrecall:latest $ECR_URL:latest
docker push $ECR_URL:latest

# Force new deployment
aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --force-new-deployment
```

### Update Infrastructure

```bash
# Modify variables in terraform.tfvars
# Then apply changes
terraform apply
```

## Troubleshooting

### Tasks Not Starting

Check logs:
```bash
aws logs tail /ecs/localrecall --follow
```

Common issues:
- Image not found in ECR
- Invalid environment variables
- EFS mount failure (check security groups)
- Insufficient CPU/memory

### EFS Mount Failures

Verify:
1. EFS mount targets exist in same subnets as tasks
2. Security group allows NFS (port 2049) from ECS tasks
3. EFS access points are configured correctly

```bash
aws efs describe-file-systems --file-system-id $(terraform output -raw efs_file_system_id)
aws efs describe-mount-targets --file-system-id $(terraform output -raw efs_file_system_id)
```

### Scale-to-Zero Not Working

Check auto scaling activity:
```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/$(terraform output -raw ecs_cluster_name)/$(terraform output -raw ecs_service_name)
```

Ensure:
- `min_capacity = 0` in configuration
- Scale-in cooldown period has elapsed (default 300 seconds)
- No active requests to the ALB

### High Costs

Review:
1. NAT Gateway usage (most expensive component)
2. EFS storage and throughput
3. Fargate running time
4. ALB data transfer

## Security Hardening

### Enable HTTPS

1. Request ACM certificate:
```bash
aws acm request-certificate \
  --domain-name your-domain.com \
  --validation-method DNS
```

2. Add HTTPS listener:
```hcl
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = "arn:aws:acm:region:account:certificate/xxx"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}
```

### Enable API Authentication

Set `API_KEYS` environment variable in task definition:

```hcl
{
  name  = "API_KEYS"
  value = "key1,key2,key3"
}
```

### Restrict Access

Update ALB security group to allow only specific IPs:

```hcl
ingress {
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["your-office-ip/32"]
}
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning**: This will delete:
- EFS file system (all data will be lost!)
- ECS cluster and services
- Load balancer
- VPC and networking

To preserve data, backup EFS before destroying:
```bash
# Mount EFS locally and backup
# Or use AWS Backup service
```

## Advanced Configuration

### Multi-Region Deployment

Copy terraform directory and configure different regions:

```bash
cp -r terraform terraform-eu-west-1
cd terraform-eu-west-1
# Update terraform.tfvars with region = "eu-west-1"
terraform init
terraform apply
```

### Blue/Green Deployment

Use ECS deployment circuit breaker:

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

### Private Deployment (No Internet)

1. Remove NAT Gateway
2. Use VPC endpoints for AWS services:
   - ECR
   - CloudWatch Logs
   - ECS
3. Deploy LocalAI in same VPC

### Database Backup

Enable AWS Backup for EFS:

```hcl
resource "aws_backup_vault" "efs" {
  name = "localrecall-efs-backup"
}

resource "aws_backup_plan" "efs" {
  name = "localrecall-efs-backup-plan"

  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.efs.name
    schedule          = "cron(0 2 * * ? *)"

    lifecycle {
      delete_after = 30
    }
  }
}
```

## Support

For issues specific to:
- **LocalRecall application**: See main repository issues
- **AWS Fargate/ECS**: AWS Support or documentation
- **Terraform**: Terraform documentation or HashiCorp support
