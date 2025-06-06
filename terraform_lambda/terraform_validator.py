# terraform_validator.py - Lambda handler for Terraform validation

import json
import os
import boto3
import subprocess
import tempfile
import logging
import shutil
import re

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')

# Get environment variables
STATE_BUCKET = os.environ['STATE_BUCKET']
SNS_TOPIC = os.environ['SNS_TOPIC']

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

def basic_syntax_check(file_path):
    """
    Perform a basic syntax check of the Terraform file
    """
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Check for basic syntax errors
    errors = []
    
    # Check for unbalanced braces
    open_braces = content.count('{')
    close_braces = content.count('}')
    if open_braces != close_braces:
        errors.append(f"Unbalanced braces: {open_braces} opening vs {close_braces} closing")
    
    # Check for unbalanced quotes
    double_quotes = len(re.findall(r'(?<!\\)"', content))
    if double_quotes % 2 != 0:
        errors.append(f"Unbalanced double quotes: {double_quotes} found")
    
    # Check for basic provider blocks
    if "provider" not in content:
        errors.append("No provider block found")
    
    return errors

def lambda_handler(event, context):
    """
    Validate the Terraform code generated by the NLP converter
    """
    try:
        # Extract information from the previous step
        request_id = event['requestId']
        s3_bucket = event['s3Bucket']
        s3_key = event['s3Key']
        
        logger.info(f"Validating Terraform code for request: {request_id}")
        
        # Create temporary directory for Terraform files
        with tempfile.TemporaryDirectory() as temp_dir:
            # Download Terraform code from S3
            terraform_file_path = os.path.join(temp_dir, "main.tf")
            s3_client.download_file(s3_bucket, s3_key, terraform_file_path)
            
            # Clean the Terraform file to remove any formatting characters
            clean_terraform_file(terraform_file_path)
            
            # Perform basic syntax check
            syntax_errors = basic_syntax_check(terraform_file_path)
            
            if syntax_errors:
                error_message = "Terraform syntax validation failed:\n" + "\n".join(syntax_errors)
                raise Exception(error_message)
            
            # Read the file content for reference
            with open(terraform_file_path, 'r') as f:
                terraform_content = f.read()
            
            # Store validation results in S3
            validation_result = {
                "syntax_check": "PASSED" if not syntax_errors else "FAILED",
                "errors": syntax_errors,
                "status": "SUCCESS" if not syntax_errors else "FAILED"
            }
            
            s3_client.put_object(
                Bucket=s3_bucket,
                Key=f"terraform_validation/{request_id}/validation_result.json",
                Body=json.dumps(validation_result)
            )
            
            # Return the information needed for the next step
            return {
                "requestId": request_id,
                "s3Bucket": s3_bucket,
                "s3TerraformKey": s3_key,
                "s3ValidationKey": f"terraform_validation/{request_id}/validation_result.json",
                "status": "SUCCESS",
                "message": "Successfully validated Terraform code"
            }
            
    except Exception as e:
        logger.error(f"Error validating Terraform code: {str(e)}")
        
        # Notify about the error
        sns_client.publish(
            TopicArn=SNS_TOPIC,
            Subject=f"Error in Terraform Validation",
            Message=f"Failed to validate Terraform code for request {event.get('requestId', 'unknown')}: {str(e)}"
        )
        
        raise e