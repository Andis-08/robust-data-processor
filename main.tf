provider "aws" {
  region = "us-east-1" # Change as needed
}

# --- 1. STORAGE (DynamoDB) ---
resource "aws_dynamodb_table" "logs_table" {
  name           = "MultiTenantLogs"
  billing_mode   = "PAY_PER_REQUEST" # Free tier friendly
  hash_key       = "tenant_id"       # Partition Key (Isolation)
  range_key      = "log_id"          # Sort Key

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "log_id"
    type = "S"
  }
}

# --- 2. ORCHESTRATION (SQS) ---
resource "aws_sqs_queue" "ingest_queue" {
  name                       = "ingest-queue"
  visibility_timeout_seconds = 900 # Must be > Lambda timeout
  message_retention_seconds  = 345600
}

# --- 3. COMPUTE (Lambdas & IAM Refactor) ---

# ZIP the python files
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_file = "ingest.py"
  output_path = "ingest.zip"
}

data "archive_file" "worker_zip" {
  type        = "zip"
  source_file = "worker.py"
  output_path = "worker.zip"
}

# --- ROLE A: INGEST (Write to SQS only) ---
resource "aws_iam_role" "ingest_role" {
  name = "ingest_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ingest_basic" {
  role       = aws_iam_role.ingest_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ingest_policy" {
  name = "ingest_sqs_write"
  role = aws_iam_role.ingest_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.ingest_queue.arn
      }
    ]
  })
}

# --- ROLE B: WORKER (Read SQS + Write DynamoDB) ---
resource "aws_iam_role" "worker_role" {
  name = "worker_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_basic" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "worker_processing_policy"
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.ingest_queue.arn
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.logs_table.arn
      }
    ]
  })
}

# --- LAMBDA FUNCTIONS ---

resource "aws_lambda_function" "ingest_lambda" {
  filename         = "ingest.zip"
  function_name    = "IngestAPI"
  role             = aws_iam_role.ingest_role.arn # Updated Role
  handler          = "ingest.lambda_handler"
  runtime          = "python3.9"
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256
  timeout          = 900

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.ingest_queue.id
    }
  }
}

resource "aws_lambda_function" "worker_lambda" {
  filename         = "worker.zip"
  function_name    = "LogWorker"
  role             = aws_iam_role.worker_role.arn # Updated Role
  handler          = "worker.lambda_handler"
  runtime          = "python3.9"
  source_code_hash = data.archive_file.worker_zip.output_base64sha256
  timeout          = 900

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.logs_table.name
    }
  }
}

# Trigger Worker from SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.ingest_queue.arn
  function_name    = aws_lambda_function.worker_lambda.arn
  batch_size       = 5
  # ADDED: This enables the worker to say "Message A passed, but Message B failed"
  function_response_types = ["ReportBatchItemFailures"]
}

# --- 4. API GATEWAY ---
resource "aws_apigatewayv2_api" "http_api" {
  name          = "LogIngestGateway"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.http_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.ingest_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ingest_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /ingest"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*/ingest"
}

# --- 5. EVALUATOR ACCESS (Submission Requirement) ---

resource "aws_iam_user" "evaluator" {
  name = "backend_evaluator"
}

resource "aws_iam_access_key" "evaluator_key" {
  user = aws_iam_user.evaluator.name
}

resource "aws_iam_user_policy" "evaluator_read_only" {
  name = "DynamoDBReadOnly"
  user = aws_iam_user.evaluator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:Scan",
          "dynamodb:Query",
          "dynamodb:BatchGetItem",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.logs_table.arn
      }
    ]
  })
}

# --- OUTPUTS ---
output "api_endpoint" {
  description = "The URL to submit for the task"
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/ingest"
}

output "evaluator_access_key" {
  description = "Access Key ID for the evaluator to inspect DB"
  value       = aws_iam_access_key.evaluator_key.id
}

output "evaluator_secret_key" {
  description = "Secret Key for the evaluator (Run 'terraform output -raw evaluator_secret_key' to view)"
  value       = aws_iam_access_key.evaluator_key.secret
  sensitive   = true
}
