# outputs.tf - Output values

output "step_function_arn" {
  description = "ARN of the Step Function state machine"
  value       = aws_sfn_state_machine.terraform_orchestrator.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for deployment notifications"
  value       = aws_sns_topic.deployment_notifications.arn
}

output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "nlp_to_terraform_lambda_arn" {
  description = "ARN of the NLP to Terraform Lambda function"
  value       = aws_lambda_function.nlp_to_terraform.arn
}

output "terraform_validator_lambda_arn" {
  description = "ARN of the Terraform validator Lambda function"
  value       = aws_lambda_function.terraform_validator.arn
}

output "terraform_applier_lambda_arn" {
  description = "ARN of the Terraform applier Lambda function"
  value       = aws_lambda_function.terraform_applier.arn
}