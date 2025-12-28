variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name to use for resource naming"
  type        = string
  default     = "localrecall"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "task_cpu" {
  description = "Fargate task CPU units"
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Fargate task memory in MiB"
  type        = string
  default     = "1024"
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "embedding_model" {
  description = "Embedding model to use"
  type        = string
  default     = "granite-embedding-107m-multilingual"
}

variable "openai_api_key" {
  description = "OpenAI API key (or LocalAI key)"
  type        = string
  sensitive   = true
  default     = "sk-1234567890"
}

variable "openai_base_url" {
  description = "OpenAI base URL (LocalAI endpoint)"
  type        = string
  default     = "http://localai:8080"
}

variable "initial_desired_count" {
  description = "Initial desired count of ECS tasks"
  type        = number
  default     = 1
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks (set to 0 for scale-to-zero)"
  type        = number
  default     = 0
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks"
  type        = number
  default     = 10
}

variable "scaling_target_requests" {
  description = "Target number of requests per target for auto scaling"
  type        = number
  default     = 100
}

variable "scale_in_cooldown" {
  description = "Scale in cooldown period in seconds"
  type        = number
  default     = 300
}

variable "scale_out_cooldown" {
  description = "Scale out cooldown period in seconds"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "LocalRecall"
    ManagedBy   = "Terraform"
    Environment = "production"
  }
}
