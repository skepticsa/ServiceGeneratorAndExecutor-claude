# nlp_converter.py - Lambda handler for NLP to Terraform conversion
import json
import os
import boto3
import uuid
import logging
from botocore.exceptions import ClientError
# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)
# Initialize AWS clients
bedrock_runtime = boto3.client('bedrock-runtime')
s3_client = boto3.client('s3')
sns_client = boto3.client('sns')
# Get environment variables
STATE_BUCKET = os.environ['STATE_BUCKET']
SNS_TOPIC = os.environ['SNS_TOPIC']
def lambda_handler(event, context):
    """
    Process natural language input, convert to Terraform code using Bedrock
    """
    try:
        # Extract the natural language request
        natural_language_request = event['input']
        request_id = str(uuid.uuid4())
        logger.info(f"Processing request: {request_id}")
        logger.info(f"Natural language input: {natural_language_request}")
        
        # Using the Messages API format for Claude 3 models
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4096,
            "temperature": 0.7,
            "top_p": 0.9,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"""You are an expert AWS architect and Terraform developer.
Convert the following infrastructure requirement into valid Terraform code.
Include appropriate providers, resources, and variables.
Use best practices for AWS infrastructure and Terraform code.

Requirement: {natural_language_request}

Respond with ONLY the Terraform code, no explanations or comments outside of the code."""
                        }
                    ]
                }
            ]
        }
        
        # Call Bedrock to generate Terraform code
        response = bedrock_runtime.invoke_model(
            modelId='anthropic.claude-3-sonnet-20240229-v1:0',
            contentType='application/json',
            accept='application/json',
            body=json.dumps(request_body)
        )
        
        # Parse Bedrock response for Messages API
        response_body = json.loads(response['body'].read())
        terraform_code = response_body['content'][0]['text']
        
        # Store Terraform code in S3
        s3_key = f"terraform_code/{request_id}/main.tf"
        s3_client.put_object(
            Bucket=STATE_BUCKET,
            Key=s3_key,
            Body=terraform_code
        )
        
        # Return the information needed for the next step
        return {
            'requestId': request_id,
            's3Bucket': STATE_BUCKET,
            's3Key': s3_key,
            'status': 'SUCCESS',
            'message': 'Successfully converted natural language to Terraform code'
        }
    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
        # Notify about the error
        sns_client.publish(
            TopicArn=SNS_TOPIC,
            Subject=f"Error in NLP to Terraform Conversion",
            Message=f"Failed to process request: {str(e)}"
        )
        raise e