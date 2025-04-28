# variables.tf - Variable definitions

variable "aws_region" {
  description = "The AWS region to deploy resources to"
  type        = string
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID to use"
  type        = string
}

variable "lambda_timeout" {
  description = "Timeout for Lambda functions in seconds"
  type        = number
}

variable "lambda_memory_size" {
  description = "Memory size for Lambda functions in MB"
  type        = number
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
}
 
variable "notification_email" {
  description = "Email address for notifications"
  type        = string
}
