# terraform_applier.py - Lambda handler for applying Terraform

import json
import os
import boto3
import tempfile
import logging
import shutil
import subprocess
import re
import uuid
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')
lambda_client = boto3.client('lambda')

# Get environment variables
STATE_BUCKET = os.environ['STATE_BUCKET']
SNS_TOPIC = os.environ['SNS_TOPIC']
TERRAFORM_LAYER = os.environ.get('TERRAFORM_LAYER', '/opt/bin')

def clean_terraform_file(file_path):
    """
    Clean the Terraform file of any Markdown or other formatting characters
    that might have been introduced during file transfer
    """
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Check for Markdown code formatting (```hcl, ```terraform, etc.)
    if content.startswith('```'):
        # Find the first line break after the opening backticks
        first_newline = content.find('\n')
        if first_newline > 0:
            # Find the closing backticks
            closing_backticks = content.rfind('```')
            if closing_backticks > first_newline:
                # Extract just the code between the backticks
                content = content[first_newline+1:closing_backticks].strip()
            else:
                # Just remove the opening backticks line
                content = content[first_newline+1:].strip()
    
    # Write the cleaned content back to the file
    with open(file_path, 'w') as f:
        f.write(content)
    
    return content

def create_backend_config(temp_dir, request_id):
    """
    Create a backend.tf file for Terraform state management
    """
    backend_content = f"""
terraform {{
  backend "s3" {{
    bucket = "{STATE_BUCKET}"
    key    = "terraform_state/{request_id}/terraform.tfstate"
    region = "us-east-1"  # Explicitly set region
  }}
}}
"""
    backend_path = os.path.join(temp_dir, "backend.tf")
    with open(backend_path, 'w') as f:
        f.write(backend_content)
    
    return backend_path

def create_provider_config(temp_dir):
    """
    Create a versions.tf file for Terraform provider configuration
    without duplicating the provider if it already exists
    """
    # First check if provider exists in main.tf
    main_tf_path = os.path.join(temp_dir, "main.tf")
    provider_exists = False
    
    if os.path.exists(main_tf_path):
        with open(main_tf_path, 'r') as f:
            content = f.read()
            # Check if AWS provider is already defined
            provider_exists = 'provider "aws"' in content
            
            # If provider exists but doesn't have region, we need to modify it
            if provider_exists:
                logger.info("AWS provider already exists in main.tf")
                
                # Check if the provider has a region
                if 'region' not in content.split('provider "aws"')[1].split('}')[0]:
                    logger.info("Modifying main.tf to add region to AWS provider")
                    # Simple string replacement to add region
                    provider_block = content.split('provider "aws"')[1].split('}')[0]
                    new_provider_block = provider_block.rstrip() + '\n  region = "us-east-1"\n'
                    content = content.replace(provider_block, new_provider_block)
                    
                    # Write back the modified content
                    with open(main_tf_path, 'w') as f_write:
                        f_write.write(content)
    
    # Create versions.tf without provider block if it already exists
    if provider_exists:
        versions_content = """
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}
"""
    else:
        versions_content = """
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

# Explicitly set the AWS provider region to us-east-1
provider "aws" {
  region = "us-east-1"
}
"""
    
    versions_path = os.path.join(temp_dir, "versions.tf")
    with open(versions_path, 'w') as f:
        f.write(versions_content)
    
    return versions_path

def setup_aws_credentials(temp_dir):
    """
    Create AWS provider configuration and credentials
    """
    # Create AWS config directory
    aws_dir = os.path.join(temp_dir, '.aws')
    os.makedirs(aws_dir, exist_ok=True)
    
    # Create credentials file
    credentials_content = """
[default]
region = us-east-1
"""
    credentials_path = os.path.join(aws_dir, 'config')
    with open(credentials_path, 'w') as f:
        f.write(credentials_content)
    
    logger.info(f"Created AWS config in {credentials_path}")
    
    # Update Lambda environment to use this config
    os.environ['AWS_CONFIG_FILE'] = credentials_path
    
    return credentials_path

def run_terraform_command(command, work_dir):
    """
    Run a Terraform command in the specified directory
    """
    # Find the terraform binary
    terraform_bin = os.path.join(TERRAFORM_LAYER, 'terraform')
    
    # Log path information for debugging
    logger.info(f"Looking for Terraform binary at: {terraform_bin}")
    logger.info(f"Directory contents of /opt: {os.listdir('/opt')}")
    
    try:
        # Check bin directory if it exists
        if os.path.exists('/opt/bin'):
            logger.info(f"Directory contents of /opt/bin: {os.listdir('/opt/bin')}")
    except Exception as e:
        logger.warning(f"Unable to list directory contents: {str(e)}")
    
    # Verify the terraform binary exists
    if not os.path.isfile(terraform_bin):
        logger.error(f"Terraform binary not found at {terraform_bin}")
        # Try to find the terraform binary in the Lambda environment
        terraform_path = None
        for root, dirs, files in os.walk('/opt'):
            if 'terraform' in files:
                terraform_path = os.path.join(root, 'terraform')
                logger.info(f"Found terraform at {terraform_path}")
                terraform_bin = terraform_path
                break
        
        if terraform_path is None:
            raise FileNotFoundError(f"Terraform binary not found in Lambda environment")
    
    # Do NOT try to chmod the terraform binary - it's in a read-only filesystem
    # Instead, copy it to /tmp which is writable
    tmp_terraform = os.path.join('/tmp', 'terraform')
    logger.info(f"Copying terraform binary to {tmp_terraform}")
    shutil.copy2(terraform_bin, tmp_terraform)
    os.chmod(tmp_terraform, 0o755)
    
    # Set up the environment - FORCE US-EAST-1 REGION
    env = os.environ.copy()
    env['TF_IN_AUTOMATION'] = 'true'
    env['AWS_REGION'] = 'us-east-1'
    env['AWS_DEFAULT_REGION'] = 'us-east-1'
    # Add temporary directory to PATH
    env['PATH'] = f"/tmp:{env.get('PATH', '')}"
    
    # Log environment variables being used
    logger.info(f"Environment variables for Terraform: AWS_REGION={env.get('AWS_REGION')}, AWS_DEFAULT_REGION={env.get('AWS_DEFAULT_REGION')}")
    
    # Run the command using the executable in /tmp
    try:
        logger.info(f"Running Terraform command: {command} in directory {work_dir}")
        process = subprocess.Popen(
            [tmp_terraform] + command,
            cwd=work_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env
        )
        stdout, stderr = process.communicate(timeout=780)  # 13 min timeout
        
        stdout_str = stdout.decode('utf-8')
        stderr_str = stderr.decode('utf-8')
        
        # Log the command output for debugging
        logger.info(f"Terraform command output: {stdout_str}")
        if stderr_str:
            logger.info(f"Terraform command error output: {stderr_str}")
        
        if process.returncode != 0:
            logger.error(f"Terraform command failed: {stderr_str}")
            return False, stderr_str
        
        return True, stdout_str
    except subprocess.TimeoutExpired:
        process.kill()
        logger.error("Terraform command timed out")
        return False, "Command timed out after 4 minutes"
    except Exception as e:
        logger.error(f"Error running Terraform command: {str(e)}")
        return False, str(e)

def lambda_handler(event, context):
    """
    Apply the validated Terraform code
    """
    try:
        # Extract information from the previous step
        request_id = event['requestId']
        s3_bucket = event['s3Bucket']
        s3_terraform_key = event['s3TerraformKey']
        
        logger.info(f"Applying Terraform code for request: {request_id}")
        logger.info(f"Environment variables: STATE_BUCKET={STATE_BUCKET}, TERRAFORM_LAYER={TERRAFORM_LAYER}")
        
        # Create temporary directory for Terraform files
        with tempfile.TemporaryDirectory() as temp_dir:
            # Set up AWS credentials with correct region
            setup_aws_credentials(temp_dir)
            
            # Force AWS region for boto3 clients
            os.environ['AWS_REGION'] = 'us-east-1'
            os.environ['AWS_DEFAULT_REGION'] = 'us-east-1'
            
            # Download Terraform code from S3
            terraform_file_path = os.path.join(temp_dir, "main.tf")
            s3_client.download_file(s3_bucket, s3_terraform_key, terraform_file_path)
            
            # Log the Terraform code for debugging
            with open(terraform_file_path, 'r') as f:
                terraform_code = f.read()
                logger.info(f"Downloaded Terraform code: {terraform_code}")
            
            # Clean the Terraform file
            terraform_content = clean_terraform_file(terraform_file_path)
            
            # Create backend configuration
            create_backend_config(temp_dir, request_id)
            
            # Create provider versions with explicit region
            create_provider_config(temp_dir)
            
            # Set AWS_REGION environment variable for Terraform
            env_vars_file = os.path.join(temp_dir, "terraform.tfvars")
            with open(env_vars_file, 'w') as f:
                f.write('aws_region = "us-east-1"\n')
            
            # Log the directory content for debugging
            logger.info(f"Directory contents of {temp_dir}: {os.listdir(temp_dir)}")
            
            # Initialize Terraform
            success, output = run_terraform_command(['init'], temp_dir)
            if not success:
                raise Exception(f"Terraform init failed: {output}")
            
            # Create a plan file
            plan_file = os.path.join(temp_dir, "tfplan")
            success, output = run_terraform_command(['plan', '-out=tfplan'], temp_dir)
            if not success:
                raise Exception(f"Terraform plan failed: {output}")
            
            # Upload the plan to S3
            s3_client.upload_file(
                plan_file,
                s3_bucket,
                f"terraform_plans/{request_id}/tfplan"
            )
            
            # Apply the plan
            success, output = run_terraform_command(['apply', '-auto-approve', 'tfplan'], temp_dir)
            
            # Store the apply output
            s3_client.put_object(
                Bucket=s3_bucket,
                Key=f"terraform_output/{request_id}/apply_output.txt",
                Body=output
            )
            
            if not success:
                raise Exception(f"Terraform apply failed: {output}")
            
            # Get the outputs
            success, tf_output = run_terraform_command(['output', '-json'], temp_dir)
            if success:
                s3_client.put_object(
                    Bucket=s3_bucket,
                    Key=f"terraform_output/{request_id}/outputs.json",
                    Body=tf_output
                )
            
            # Notify about the result
            sns_client.publish(
                TopicArn=SNS_TOPIC,
                Subject=f"Terraform Deployment {request_id} Completed",
                Message=f"""
Terraform deployment completed successfully for request {request_id}.

Outputs have been stored at s3://{s3_bucket}/terraform_output/{request_id}/outputs.json
Apply logs have been stored at s3://{s3_bucket}/terraform_output/{request_id}/apply_output.txt
                """
            )
            
            # Return the final result
            return {
                "requestId": request_id,
                "s3Bucket": s3_bucket,
                "s3TerraformKey": s3_terraform_key,
                "s3OutputsKey": f"terraform_output/{request_id}/outputs.json",
                "s3ApplyLogsKey": f"terraform_output/{request_id}/apply_output.txt",
                "status": "SUCCESS",
                "message": "Successfully deployed infrastructure using Terraform"
            }
            
    except Exception as e:
        logger.error(f"Error applying Terraform code: {str(e)}")
        
        # Notify about the error
        sns_client.publish(
            TopicArn=SNS_TOPIC,
            Subject=f"Error in Terraform Apply",
            Message=f"Failed to apply Terraform code for request {event.get('requestId', 'unknown')}: {str(e)}"
        )
        
        raise e
    