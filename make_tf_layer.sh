# Create directory structure - note we're using /opt/bin not /opt/terraform
mkdir -p terraform_layer/opt/bin

# Download Terraform binary for Amazon Linux 2
curl -o terraform_1.11.4_linux_amd64.zip https://releases.hashicorp.com/terraform/1.11.4/terraform_1.11.4_linux_amd64.zip

# Unzip the binary to the correct bin directory
unzip terraform_1.11.4_linux_amd64.zip -d terraform_layer/opt/bin

# Ensure it's executable
chmod +x terraform_layer/opt/bin/terraform

# Create the Lambda layer zip
cd terraform_layer
zip -r ../terraform.zip .
cd ..

# Upload to AWS
aws lambda publish-layer-version \
  --layer-name terraform-binary-layer \
  --description "Terraform binary for Lambda" \
  --zip-file fileb://terraform.zip \
  --compatible-runtimes python3.11

