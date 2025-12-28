# AWS Fargate Deployment Guide

This guide provides step-by-step instructions for deploying LocalRecall on AWS Fargate with EFS for persistent storage and scale-to-zero capabilities.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Docker installed locally
- AWS account with permissions to create ECS, EFS, VPC, and ALB resources
- LocalAI instance accessible from AWS (or deploy alongside)

## Architecture Overview

```
Internet → ALB → Fargate Tasks (ECS Service) → EFS
                       ↓
                  LocalAI (for embeddings)
```

## Deployment Steps

### Step 1: Prepare the Docker Image

1. **Build the Docker image:**
   ```bash
   docker build -t localrecall:latest .
   ```

2. **Create ECR repository:**
   ```bash
   aws ecr create-repository --repository-name localrecall --region us-east-1
   ```

3. **Authenticate Docker to ECR:**
   ```bash
   aws ecr get-login-password --region us-east-1 | \
     docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
   ```

4. **Tag and push the image:**
   ```bash
   docker tag localrecall:latest <account-id>.dkr.ecr.us-east-1.amazonaws.com/localrecall:latest
   docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/localrecall:latest
   ```

### Step 2: Create VPC and Networking (if needed)

If you don't have an existing VPC, create one:

```bash
aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=localrecall-vpc}]'

# Create subnets in different AZs
aws ec2 create-subnet --vpc-id <vpc-id> --cidr-block 10.0.1.0/24 --availability-zone us-east-1a
aws ec2 create-subnet --vpc-id <vpc-id> --cidr-block 10.0.2.0/24 --availability-zone us-east-1b

# Create Internet Gateway
aws ec2 create-internet-gateway
aws ec2 attach-internet-gateway --vpc-id <vpc-id> --internet-gateway-id <igw-id>

# Configure route table
aws ec2 create-route --route-table-id <rt-id> --destination-cidr-block 0.0.0.0/0 --gateway-id <igw-id>
```

### Step 3: Create Amazon EFS

1. **Create EFS filesystem:**
   ```bash
   aws efs create-file-system \
     --creation-token localrecall-efs-$(date +%s) \
     --performance-mode generalPurpose \
     --throughput-mode bursting \
     --encrypted \
     --tags Key=Name,Value=localrecall-efs
   ```

2. **Create mount targets in each subnet:**
   ```bash
   # Create security group for EFS
   aws ec2 create-security-group \
     --group-name localrecall-efs-sg \
     --description "Security group for LocalRecall EFS" \
     --vpc-id <vpc-id>

   # Allow NFS traffic from Fargate tasks
   aws ec2 authorize-security-group-ingress \
     --group-id <efs-sg-id> \
     --protocol tcp \
     --port 2049 \
     --source-group <fargate-sg-id>

   # Create mount targets
   aws efs create-mount-target \
     --file-system-id <fs-id> \
     --subnet-id <subnet-1-id> \
     --security-groups <efs-sg-id>

   aws efs create-mount-target \
     --file-system-id <fs-id> \
     --subnet-id <subnet-2-id> \
     --security-groups <efs-sg-id>
   ```

3. **Create EFS Access Points:**
   ```bash
   # Access point for database
   aws efs create-access-point \
     --file-system-id <fs-id> \
     --posix-user Uid=1000,Gid=1000 \
     --root-directory Path=/db,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755} \
     --tags Key=Name,Value=localrecall-db

   # Access point for assets
   aws efs create-access-point \
     --file-system-id <fs-id> \
     --posix-user Uid=1000,Gid=1000 \
     --root-directory Path=/assets,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755} \
     --tags Key=Name,Value=localrecall-assets
   ```

### Step 4: Create ECS Cluster

```bash
aws ecs create-cluster --cluster-name localrecall-cluster
```

### Step 5: Create Task Execution Role

Create IAM role for task execution:

```bash
# Create trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name localrecallTaskExecutionRole \
  --assume-role-policy-document file://trust-policy.json

# Attach managed policies
aws iam attach-role-policy \
  --role-name localrecallTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

### Step 6: Create Task Definition

Create `task-definition.json`:

```json
{
  "family": "localrecall",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::<account-id>:role/localrecallTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "localrecall",
      "image": "<account-id>.dkr.ecr.us-east-1.amazonaws.com/localrecall:latest",
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "COLLECTION_DB_PATH",
          "value": "/db"
        },
        {
          "name": "FILE_ASSETS",
          "value": "/assets"
        },
        {
          "name": "EMBEDDING_MODEL",
          "value": "granite-embedding-107m-multilingual"
        },
        {
          "name": "OPENAI_API_KEY",
          "value": "sk-1234567890"
        },
        {
          "name": "OPENAI_BASE_URL",
          "value": "http://localai:8080"
        },
        {
          "name": "VECTOR_ENGINE",
          "value": "chromem"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "db",
          "containerPath": "/db",
          "readOnly": false
        },
        {
          "sourceVolume": "assets",
          "containerPath": "/assets",
          "readOnly": false
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/localrecall",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ],
  "volumes": [
    {
      "name": "db",
      "efsVolumeConfiguration": {
        "fileSystemId": "<efs-id>",
        "transitEncryption": "ENABLED",
        "authorizationConfig": {
          "accessPointId": "<db-access-point-id>"
        }
      }
    },
    {
      "name": "assets",
      "efsVolumeConfiguration": {
        "fileSystemId": "<efs-id>",
        "transitEncryption": "ENABLED",
        "authorizationConfig": {
          "accessPointId": "<assets-access-point-id>"
        }
      }
    }
  ]
}
```

Register the task definition:

```bash
# Create CloudWatch log group first
aws logs create-log-group --log-group-name /ecs/localrecall

# Register task definition
aws ecs register-task-definition --cli-input-json file://task-definition.json
```

### Step 7: Create Application Load Balancer

1. **Create ALB:**
   ```bash
   aws elbv2 create-load-balancer \
     --name localrecall-alb \
     --subnets <subnet-1-id> <subnet-2-id> \
     --security-groups <alb-sg-id> \
     --scheme internet-facing \
     --type application
   ```

2. **Create Target Group:**
   ```bash
   aws elbv2 create-target-group \
     --name localrecall-tg \
     --protocol HTTP \
     --port 8080 \
     --vpc-id <vpc-id> \
     --target-type ip \
     --health-check-path /health \
     --health-check-interval-seconds 30 \
     --healthy-threshold-count 2 \
     --unhealthy-threshold-count 3
   ```

3. **Create Listener:**
   ```bash
   aws elbv2 create-listener \
     --load-balancer-arn <alb-arn> \
     --protocol HTTP \
     --port 80 \
     --default-actions Type=forward,TargetGroupArn=<tg-arn>
   ```

### Step 8: Create ECS Service

```bash
aws ecs create-service \
  --cluster localrecall-cluster \
  --service-name localrecall-service \
  --task-definition localrecall \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet-1-id>,<subnet-2-id>],securityGroups=[<fargate-sg-id>],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=<tg-arn>,containerName=localrecall,containerPort=8080" \
  --health-check-grace-period-seconds 60
```

### Step 9: Configure Auto Scaling (Scale-to-Zero)

1. **Register scalable target:**
   ```bash
   aws application-autoscaling register-scalable-target \
     --service-namespace ecs \
     --scalable-dimension ecs:service:DesiredCount \
     --resource-id service/localrecall-cluster/localrecall-service \
     --min-capacity 0 \
     --max-capacity 10
   ```

2. **Create scaling policy:**
   ```bash
   aws application-autoscaling put-scaling-policy \
     --service-namespace ecs \
     --scalable-dimension ecs:service:DesiredCount \
     --resource-id service/localrecall-cluster/localrecall-service \
     --policy-name localrecall-scaling-policy \
     --policy-type TargetTrackingScaling \
     --target-tracking-scaling-policy-configuration file://scaling-policy.json
   ```

   `scaling-policy.json`:
   ```json
   {
     "TargetValue": 100.0,
     "PredefinedMetricSpecification": {
       "PredefinedMetricType": "ALBRequestCountPerTarget",
       "ResourceLabel": "app/<alb-name>/<alb-id>/targetgroup/<tg-name>/<tg-id>"
     },
     "ScaleInCooldown": 300,
     "ScaleOutCooldown": 60
   }
   ```

## Health Check Endpoint

Add this to `routes.go`:

```go
func registerAPIRoutes(e *echo.Echo, openAIClient *openai.Client, maxChunkingSize int, apiKeys []string) {
    // Add health check endpoint
    e.GET("/health", func(c echo.Context) error {
        return c.JSON(http.StatusOK, map[string]string{"status": "healthy"})
    })

    // ... rest of the routes
}
```

## Testing the Deployment

1. **Get ALB DNS name:**
   ```bash
   aws elbv2 describe-load-balancers --names localrecall-alb --query 'LoadBalancers[0].DNSName' --output text
   ```

2. **Test health endpoint:**
   ```bash
   curl http://<alb-dns-name>/health
   ```

3. **Create a collection:**
   ```bash
   curl -X POST http://<alb-dns-name>/api/collections \
     -H "Content-Type: application/json" \
     -d '{"name":"test-collection"}'
   ```

## Monitoring

1. **View logs:**
   ```bash
   aws logs tail /ecs/localrecall --follow
   ```

2. **Check ECS service status:**
   ```bash
   aws ecs describe-services \
     --cluster localrecall-cluster \
     --services localrecall-service
   ```

3. **Monitor auto-scaling:**
   ```bash
   aws application-autoscaling describe-scaling-activities \
     --service-namespace ecs \
     --resource-id service/localrecall-cluster/localrecall-service
   ```

## Cost Optimization Tips

1. **Use Fargate Spot** for non-critical workloads (70% discount):
   ```bash
   --capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1
   ```

2. **Adjust scaling cooldown** periods to reduce task churn

3. **Monitor EFS usage** and enable lifecycle policies to move old data to Infrequent Access storage class

4. **Use AWS Savings Plans** for predictable baseline load

## Troubleshooting

### EFS Mount Failures
- Verify security group allows NFS (port 2049)
- Check mount targets exist in same subnets as Fargate tasks
- Ensure task execution role has EFS permissions

### Tasks Not Starting
- Check CloudWatch logs for errors
- Verify ECR image is accessible
- Confirm task has sufficient CPU/memory

### Scale-to-Zero Not Working
- Verify min capacity is set to 0
- Check that scaling metric is configured correctly
- Allow sufficient time for scale-in cooldown

### Cold Start Too Slow
- Increase task resources (CPU/memory)
- Pre-warm collections at startup
- Consider keeping min capacity at 1 during business hours

## Next Steps

1. Set up CI/CD pipeline to automate deployments
2. Configure HTTPS with ACM certificate
3. Add CloudWatch dashboards for monitoring
4. Implement blue/green deployments
5. Set up backup strategy for EFS
