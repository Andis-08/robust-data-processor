import json
import boto3
import time
import os
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ['TABLE_NAME']
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    batch_item_failures = []
    
    # SQS triggers Lambda with a batch of records
    for record in event['Records']:
        try:
            # 1. Parse Message
            body = json.loads(record['body'])
            tenant_id = body.get('tenant_id')
            log_id = body.get('log_id')
            text = body.get('original_text', '')
            
            print(f"Processing {log_id} for tenant {tenant_id}")

            # 2. Simulate Heavy Processing
            # Requirement: Sleep 0.05s per character
            sleep_time = len(text) * 0.05
            
            # Safety cap to prevent Lambda timeout (optional, but good practice)
            if sleep_time > 800:
                print(f"Warning: text too long, capping sleep at 800s")
                sleep_time = 800
                
            time.sleep(sleep_time)

            # 3. Save to NoSQL (DynamoDB)
            item = {
                'tenant_id': tenant_id,
                'log_id': log_id,
                'source': body.get('source'),
                'original_text': text,
                'modified_data': f"{text[:10]}... [REDACTED]", 
                'processed_at': datetime.utcnow().isoformat(),
            }
            
            table.put_item(Item=item)
            
        except Exception as e:
            print(f"Failed to process record {record['messageId']}: {e}")
            # Add the failed message ID to the list. 
            # SQS will ONLY retry the messages in this list.
            batch_item_failures.append({"itemIdentifier": record['messageId']})
            
    return {"batchItemFailures": batch_item_failures}
