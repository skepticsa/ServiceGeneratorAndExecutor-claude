```mermaid
flowchart TD
    User(User) -->|Natural Language Request| API[API Gateway]
    API -->|Start Execution| StepFunc[Step Functions Workflow]
    
    subgraph "Step Functions Workflow"
        NLP[NLP to Terraform Lambda] --> Validator[Terraform Validator Lambda]
        Validator --> Applier[Terraform Applier Lambda]
        Applier --> Success[Notify Success]
        NLP --> |Error| Failure[Notify Failure]
        Validator --> |Error| Failure
        Applier --> |Error| Failure
    end
    
    NLP <--> Bedrock[Amazon Bedrock]
    NLP --> S3Terraform[(S3 - Terraform Code)]
    Validator --> S3Terraform
    Validator --> S3Validation[(S3 - Validation Results)]
    
    Applier --> TerraformBin[/Terraform Binary\]
    Applier --> S3Output[(S3 - Terraform Output)]
    Applier --> S3State[(S3 - Terraform State)]
    Applier -->|Creates| Resources[AWS Resources]
    
    Success --> SNS[SNS Topic]
    Failure --> SNS
    SNS --> Email[Email Notification]
    
    CloudWatch[CloudWatch Logs & Alarms] --- NLP
    CloudWatch --- Validator
    CloudWatch --- Applier
    
    classDef aws fill:#FF9900,stroke:#232F3E,color:white;
    classDef lambda fill:#FF9900,stroke:#232F3E,color:white;
    classDef storage fill:#3F8624,stroke:#232F3E,color:white;
    classDef api fill:#5294CF,stroke:#232F3E,color:white;
    classDef stepfunc fill:#C925D1,stroke:#232F3E,color:white;
    classDef execution fill:#1A476F,stroke:#232F3E,color:white;
    classDef user fill:#232F3E,stroke:#232F3E,color:white;
    
    class User user;
    class API api;
    class StepFunc,Success,Failure stepfunc;
    class NLP,Validator,Applier lambda;
    class S3Terraform,S3Validation,S3Output,S3State storage;
    class Bedrock,SNS,CloudWatch,Email,Resources aws;
    class TerraformBin execution;