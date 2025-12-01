import json
import boto3
import os
import uuid
import base64

sqs = boto3.client('sqs')
QUEUE_URL = os.environ['QUEUE_URL']

def lambda_handler(event, context):
    try:
        # 1. Parse Headers (Normalize case sensitivity)
        headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
        content_type = headers.get('content-type', '')
        
        tenant_id = "unknown"
        payload_text = ""
        source_type = ""
        log_id = str(uuid.uuid4())
        
        # 2. Handle Body (Decode if base64)
        body = event.get('body', '')
        if event.get('isBase64Encoded', False):
            body = base64.b64decode(body).decode('utf-8')

        # 3. Scenario Logic
        if 'application/json' in content_type:
            source_type = "json_upload"
            # Scenario 1: Structured Data
            try:
                data = json.loads(body)
                tenant_id = data.get('tenant_id', 'unknown')
                payload_text = data.get('text', '')
                if 'log_id' in data:
                    log_id = data['log_id']
            except json.JSONDecodeError:
                return {"statusCode": 400, "body": "Invalid JSON"}
                
        elif 'text/plain' in content_type:
            source_type = "text_upload"
            # Scenario 2: Unstructured Data
            tenant_id = headers.get('x-tenant-id', 'unknown')
            payload_text = body
        
        else:
            return {"statusCode": 400, "body": "Unsupported Content-Type"}

        # 4. Construct Normalized Message
        message = {
            "tenant_id": tenant_id,
            "log_id": log_id,
            "original_text": payload_text,
            "source": source_type
        }

        # 5. Push to Queue (Async Handoff)
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message)
        )

        return {
            "statusCode": 202,
            "body": json.dumps({"status": "accepted", "id": log_id})
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {"statusCode": 500, "body": "Internal Server Error"}
