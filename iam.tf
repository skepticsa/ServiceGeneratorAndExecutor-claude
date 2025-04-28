# iam.tf - IAM roles and policies for Step Functions

# IAM Role for Step Functions
resource "aws_iam_role" "step_function_role" {
  name = "terraform_orchestrator_role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
    }]
  })
}

# Policy for Step Functions to invoke Lambda and publish to SNS
resource "aws_iam_policy" "step_function_policy" {
  name        = "terraform_orchestrator_policy"
  description = "Policy for Step Functions to orchestrate Terraform deployment"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "lambda:InvokeFunction"
        ]
        Effect   = "Allow"
        Resource = [
          aws_lambda_function.nlp_to_terraform.arn,
          aws_lambda_function.terraform_validator.arn,
          aws_lambda_function.terraform_applier.arn
        ]
      },
      {
        Action = [
          "sns:Publish"
        ]
        Effect   = "Allow"
        Resource = aws_sns_topic.deployment_notifications.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "step_function_policy_attachment" {
  role       = aws_iam_role.step_function_role.name
  policy_arn = aws_iam_policy.step_function_policy.arn
}

# IAM Role for Lambda functions to execute Terraform
resource "aws_iam_role" "terraform_execution_role" {
  name = "terraform_execution_role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Policy for Lambda to execute Terraform with necessary AWS permissions
resource "aws_iam_policy" "terraform_execution_policy" {
  name        = "terraform_execution_policy"
  description = "Policy for executing Terraform with necessary AWS permissions"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:*",
          "s3:*",
          "dynamodb:*",
          "iam:*",
          "cloudfront:*",
          "cloudwatch:*",
          "logs:*",
          "sns:*",
          "sqs:*",
          "lambda:*"
          # Add additional services as needed
        ]
        Effect   = "Allow"
        Resource = "*"
        # In production, scope these permissions more tightly
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_execution_policy_attachment" {
  role       = aws_iam_role.terraform_execution_role.name
  policy_arn = aws_iam_policy.terraform_execution_policy.arn
}