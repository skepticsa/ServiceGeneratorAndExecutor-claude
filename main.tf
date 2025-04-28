# main.tf - Main configuration file

provider "aws" {
  region = var.aws_region
}

# Store Bedrock configuration in SSM Parameter Store
resource "aws_ssm_parameter" "bedrock_model_id" {
  name  = "/terraform-nlp-agent/bedrock_model_id"
  type  = "String"
  value = var.bedrock_model_id
}

resource "aws_ssm_parameter" "bedrock_max_tokens" {
  name  = "/terraform-nlp-agent/bedrock_max_tokens"
  type  = "String"
  value = "4096"
}

resource "aws_ssm_parameter" "bedrock_temperature" {
  name  = "/terraform-nlp-agent/bedrock_temperature"
  type  = "String"
  value = "0.7"
}

# IAM Role for Lambda to access Bedrock, S3, and other services
resource "aws_iam_role" "lambda_role" {
  name = "terraform_agent_lambda_role"
  
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

# Attach policies to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_bedrock_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy for S3 and terraform deployments
resource "aws_iam_policy" "terraform_deploy_policy" {
  name        = "terraform_deployment_policy"
  description = "Policy for deploying infrastructure via Terraform"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:PutObjectAcl"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
      },
      {
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "sns:Publish"
        ]
        Effect   = "Allow"
        Resource = aws_sns_topic.deployment_notifications.arn
      },
      {
        Action = [
          "ssm:GetParameter"
        ]
        Effect   = "Allow"
        Resource = [
          aws_ssm_parameter.bedrock_model_id.arn,
          aws_ssm_parameter.bedrock_max_tokens.arn,
          aws_ssm_parameter.bedrock_temperature.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_deploy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.terraform_deploy_policy.arn
}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "terraform-nlp-agent-state-${random_string.suffix.result}"
  
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Create a Lambda layer for Terraform
resource "aws_lambda_layer_version" "terraform_layer" {
  layer_name = "terraform-binary-layer"
  description = "Contains Terraform binary for infrastructure deployment"
  
  filename = "terraform.zip"  # This should contain Terraform binary in /opt/bin/
  
  compatible_runtimes = ["python3.11"]
}

# Lambda function for NLP to Terraform conversion
resource "aws_lambda_function" "nlp_to_terraform" {
  function_name    = "nlp-to-terraform-converter"
  role             = aws_iam_role.lambda_role.arn
  handler          = "nlp_converter.lambda_handler"
  runtime          = "python3.11"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  
  filename         = "lambda_deployment.zip"
  source_code_hash = filebase64sha256("lambda_deployment.zip")
  
  environment {
    variables = {
      STATE_BUCKET        = aws_s3_bucket.terraform_state.bucket
      SNS_TOPIC           = aws_sns_topic.deployment_notifications.arn
      BEDROCK_MODEL_ID    = aws_ssm_parameter.bedrock_model_id.value
      BEDROCK_MAX_TOKENS  = aws_ssm_parameter.bedrock_max_tokens.value
      BEDROCK_TEMPERATURE = aws_ssm_parameter.bedrock_temperature.value
    }
  }
}

# Lambda function for Terraform validation
resource "aws_lambda_function" "terraform_validator" {
  function_name    = "terraform-validator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "terraform_validator.lambda_handler"
  runtime          = "python3.11"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  
  filename         = "lambda_deployment.zip"
  source_code_hash = filebase64sha256("lambda_deployment.zip")
  
  environment {
    variables = {
      STATE_BUCKET = aws_s3_bucket.terraform_state.bucket
      SNS_TOPIC    = aws_sns_topic.deployment_notifications.arn
    }
  }
}

# Lambda function for applying Terraform - increased memory and timeout
resource "aws_lambda_function" "terraform_applier" {
  function_name    = "terraform-applier"
  role             = aws_iam_role.terraform_execution_role.arn  # Use the dedicated role from iam.tf
  handler          = "terraform_applier.lambda_handler"
  runtime          = "python3.11"
  timeout          = 900  # Increased to 15 minutes (maximum allowed)
  memory_size      = 3008  # Increased to 3GB for better performance
  
  filename         = "lambda_deployment.zip"
  source_code_hash = filebase64sha256("lambda_deployment.zip")
  
  # Add the Terraform layer
  layers = [aws_lambda_layer_version.terraform_layer.arn]
  
  # Increase ephemeral storage
  ephemeral_storage {
    size = 10240  # 10GB ephemeral storage (maximum allowed)
  }
  
  environment {
    variables = {
      STATE_BUCKET     = aws_s3_bucket.terraform_state.bucket
      SNS_TOPIC        = aws_sns_topic.deployment_notifications.arn
      TERRAFORM_LAYER  = "/opt/bin"
    }
  }
}

# Step Function for orchestration
resource "aws_sfn_state_machine" "terraform_orchestrator" {
  name     = "terraform-deployment-orchestrator"
  role_arn = aws_iam_role.step_function_role.arn
  
  definition = jsonencode({
    Comment = "Orchestrates the NLP to Terraform workflow"
    StartAt = "ProcessNaturalLanguage"
    States = {
      ProcessNaturalLanguage = {
        Type = "Task"
        Resource = aws_lambda_function.nlp_to_terraform.arn
        Next = "ValidateTerraformCode"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next = "NotifyFailure"
        }]
      }
      ValidateTerraformCode = {
        Type = "Task"
        Resource = aws_lambda_function.terraform_validator.arn
        Next = "ApplyTerraform"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next = "NotifyFailure"
        }]
      }
      ApplyTerraform = {
        Type = "Task"
        Resource = aws_lambda_function.terraform_applier.arn
        Next = "NotifySuccess"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next = "NotifyFailure"
        }]
      }
      NotifySuccess = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.deployment_notifications.arn
          Message = "Terraform deployment completed successfully"
        }
        End = true
      }
      NotifyFailure = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.deployment_notifications.arn
          Message = {
            "Error.$" = "$.Error"
          }
        }
        End = true
      }
    }
  })
}

# IAM role for API Gateway to invoke Step Functions
resource "aws_iam_role" "api_gateway_role" {
  name = "api_gateway_step_functions_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "api_gateway_step_functions_policy" {
  name        = "api_gateway_step_functions_policy"
  description = "Allow API Gateway to invoke Step Functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "states:StartExecution"
        Effect   = "Allow"
        Resource = aws_sfn_state_machine.terraform_orchestrator.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_step_functions_attachment" {
  role       = aws_iam_role.api_gateway_role.name
  policy_arn = aws_iam_policy.api_gateway_step_functions_policy.arn
}

# SNS topic for notifications
resource "aws_sns_topic" "deployment_notifications" {
  name = "terraform-deployment-notifications"
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "nlp_to_terraform_logs" {
  name              = "/aws/lambda/${aws_lambda_function.nlp_to_terraform.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "terraform_validator_logs" {
  name              = "/aws/lambda/${aws_lambda_function.terraform_validator.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "terraform_applier_logs" {
  name              = "/aws/lambda/${aws_lambda_function.terraform_applier.function_name}"
  retention_in_days = var.log_retention_days
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "lambda_error_alarm" {
  alarm_name          = "terraform-nlp-agent-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "This alarm monitors for Lambda function errors"
  alarm_actions       = [aws_sns_topic.deployment_notifications.arn]
  
  dimensions = {
    FunctionName = aws_lambda_function.nlp_to_terraform.function_name
  }
}

# API Gateway for invoking the Step Function
resource "aws_api_gateway_rest_api" "terraform_api" {
  name        = "terraform-nlp-api"
  description = "API for NLP to Terraform deployments"
}

resource "aws_api_gateway_resource" "deploy_resource" {
  rest_api_id = aws_api_gateway_rest_api.terraform_api.id
  parent_id   = aws_api_gateway_rest_api.terraform_api.root_resource_id
  path_part   = "deploy"
}

resource "aws_api_gateway_method" "deploy_post" {
  rest_api_id   = aws_api_gateway_rest_api.terraform_api.id
  resource_id   = aws_api_gateway_resource.deploy_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.terraform_api.id
  resource_id = aws_api_gateway_resource.deploy_resource.id
  http_method = aws_api_gateway_method.deploy_post.http_method
  status_code = "200"
  
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration" "step_function_integration" {
  rest_api_id = aws_api_gateway_rest_api.terraform_api.id
  resource_id = aws_api_gateway_resource.deploy_resource.id
  http_method = aws_api_gateway_method.deploy_post.http_method
  
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.aws_region}:states:action/StartExecution"
  credentials             = aws_iam_role.api_gateway_role.arn
  
  request_templates = {
    "application/json" = <<EOF
{
  "input": "$util.escapeJavaScript($input.json('$'))",
  "stateMachineArn": "${aws_sfn_state_machine.terraform_orchestrator.arn}"
}
EOF
  }
  
  # Specify passthrough behavior
  passthrough_behavior = "WHEN_NO_TEMPLATES"
}

# API Gateway deployment - no stage name specified here
resource "aws_api_gateway_deployment" "terraform_api_deployment" {
  depends_on = [
    aws_api_gateway_integration.step_function_integration,
    aws_api_gateway_method_response.response_200
  ]
  
  rest_api_id = aws_api_gateway_rest_api.terraform_api.id
  
  # Use a trigger to force redeployment when changes are made
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.deploy_resource.id,
      aws_api_gateway_method.deploy_post.id,
      aws_api_gateway_integration.step_function_integration.id
    ]))
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# Create API Gateway stage separately
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.terraform_api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.terraform_api.id
  stage_name    = "prod"
}

# SNS Topic Subscription for email notifications
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.deployment_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# Random string for unique naming
resource "random_string" "suffix" {
  length  = 8
  special = false
  lower   = true
  upper   = false
}