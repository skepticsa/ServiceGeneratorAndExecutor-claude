# NLP to Terraform Deployment System - Deployment Instructions

## Prerequisites

1. AWS CLI installed and configured with appropriate credentials
2. Terraform CLI installed
3. Python 3.8 or higher
4. An AWS account with permissions to create the required resources

## Deployment Steps

### 1. Clone the Repository

Clone the repository containing the deployment files or create a new directory with all the provided files.

### 2. Create Lambda Deployment Package

```bash
# Create a directory for the package
mkdir -p package

# Install dependencies
pip install boto3 -t ./package

# Copy Lambda function code to the package directory
cp nlp_converter.py terraform_validator.py terraform_applier.py ./package/

# Create the ZIP file
cd package
zip -r ../lambda_deployment.zip .
cd ..