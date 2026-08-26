# The webhook bridge

Wrike posts events to an API Gateway endpoint backed by an AWS Lambda, which
verifies an HMAC signature and pushes the raw body onto SQS for
[the daemon](../operations/daemon.md) to pick up. Registering the webhook, the
events it subscribes to, and the Lambda's source are below.

## Set env variables

`WRIKE_API_TOKEN`, `AWS_WEBHOOK_BRIDGE`, `WRIKE_WEBHOOK_SECRET`, and `WRIKE_DASHBOARDS_FOLDER_ID`

```bash
source /data/prod/nextflow/.env
```



## Register Wrike Webhooks

Triggers when events happen in the "Dashboards" folder.

`events` restricts delivery to the four types `wrike_sqs_listener.sh` actually
routes. Without it Wrike sends every event on every task in the folder — each
status change, each custom field write, each comment the bot posts — so a single
run pushed a dozen messages through the Lambda and SQS only for the listener to
log `Ignoring unhandled event type`. **Keep this list in step with the `case`
statement in the listener; an event that is not subscribed here simply never
arrives, with nothing to show for it in any log.**

```bash
call_wrike_api POST "folders/$WRIKE_DASHBOARDS_FOLDER_ID/webhooks" \
-d "hookUrl=$AWS_WEBHOOK_BRIDGE" \
-d "secret=$WRIKE_WEBHOOK_SECRET" \
--data-urlencode "events=[TaskCreated,TaskParentsAdded,TaskDeleted,TaskParentsRemoved]"
```

| Event                | Why it is needed                                       |
| -------------------- | ------------------------------------------------------ |
| `TaskCreated`        | a request form drops a task straight into "Dashboards" |
| `TaskParentsAdded`   | `run` files an already-built task into "Dashboards"    |
| `TaskDeleted`        | the task is gone; tear the run down                    |
| `TaskParentsRemoved` | the "Dashboards" tag was pulled; tear the run down     |

```json
{
  "kind": "webhooks",
  "data": [
    {
      "id": "IEAAIKU5JAACF5JK",
      "accountId": "IEAAIKU5",
      "folderId": "MQAAAAEN9zQV",
      "hookUrl": "https://XXXXXXXXXX.execute-api.us-east-1.amazonaws.com/default/wrike-webhook-bridge",
      "events": [
        "TaskCreated",
        "TaskParentsAdded",
        "TaskDeleted",
        "TaskParentsRemoved"
      ],
      "recursive": false,
      "status": "Active"
    }
  ]
}
```

Webhooks cannot be edited, only replaced, and `events` is fixed at creation. To
narrow or widen the subscription, **delete the old webhook before registering the
new one** — two live webhooks on the same folder means every event is delivered
twice.

```bash
call_wrike_api DELETE "webhooks/IEAAIKU5JAACF5JK"
```

To see what is currently registered, and which events each one carries:

```bash
call_wrike_api GET "webhooks" | jq '.data[] | {id, status, events}'
```
```json
{
  "id": "IEAAIKU5JAACF5JK",
  "status": "Active",
  "events": [
    "TaskCreated",
    "TaskParentsAdded",
    "TaskDeleted",
    "TaskParentsRemoved"
  ]
}
```


Example webhook payload when a task is ADDED to the Dashboards folder:
```json
{
    "Messages": [
        {
            "MessageId": "a4bc2230-aa2a-4ca2-b32f-cf611fed6cf9",
            "ReceiptHandle": "AQEB2URLVgkrplZcizhbT1nxBXYZ6Pm+pwvsyt0CZKKwoROAm9jmG37K2Q5s46IF2biBSJAibdqqyehSf9QvRtpIQvn3TXw0v9L9qIzupz1nrndH73jIsGUZLsg0jcutUgUI6pBkH3yCvAIDiNbwvxRB67PywMW3rgpvAYZhC1ZP3tTvGo/JFaNIChMiQ17IjZ2OepdmIZXbLr51B/7wnYvajccEzL36DULo89IpVfWuWisi8pZSD41RH/KUhSh3HMYs+0STikfYgW8A9ob41h0TArQ9t+USxxfsVnWw2MvuQze0Z/hjK4Gq+Cv3hg9Q1x3+O168jGHfhEzy4BPgKBSdy2W6QkB5YTbaPesSU+Ll/uE/pKRm08BsAhDVy6seZwMa",
            "MD5OfBody": "333d5fe83862580c5b112858e312b182",
            "Body": "[\n  {\n    \"taskId\": \"MAAAAAEOud3s\",\n    \"webhookId\": \"IEAAIKU5JAACF45S\",\n    \"eventAuthorId\": \"KUAAXTKP\",\n    \"eventType\": \"TaskCreated\",\n    \"lastUpdatedDate\": \"2026-08-11T23:35:42Z\"\n  }\n]"
        }
    ]
}
```


That task can be investigated like this:

```bash
call_wrike_api GET tasks/$TASK_ID
```
```json
{
  "kind": "tasks",
  "data": [
    {
      "id": "MAAAAAEOud3s",
      "accountId": "IEAAIKU5",
      "title": "PQ9999999",
      "description": "<b>Settings</b><br />Default<br /><br /><b>Attach the sample sheet.</b><br />six_samples.tsv<br />",
      "briefDescription": "Settings Default Attach the sample sheet. six_samples.tsv",
      "parentIds": [
        "MQAAAAEN9zQV"
      ],
      "superParentIds": [],
      "sharedIds": [
        "KUAYXHNY",
        "KUAAXTKP"
      ],
      "responsibleIds": [
        "KUAYXHNY"
      ],
      "status": "Active",
      "importance": "Normal",
      "createdDate": "2026-08-26T19:25:49Z",
      "updatedDate": "2026-08-26T19:27:00Z",
      "dates": {
        "type": "Backlog"
      },
      "scope": "WsTask",
      "authorIds": [
        "KUAAXTKP"
      ],
      "customStatusId": "IEAAIKU5JMHRVOKU",
      "hasAttachments": true,
      "permalink": "https://www.wrike.com/open.htm?id=4542029292",
      "priority": "898f38008000000000008c00",
      "followedByMe": true,
      "followerIds": [
        "KUAYXHNY",
        "KUAAXTKP"
      ],
      "superTaskIds": [],
      "subTaskIds": [],
      "dependencyIds": [],
      "metadata": [],
      "customFields": [
        {
          "id": "IEAAIKU5JUANAH3C",
          "value": "ampliseq :: 16S full length or variable region amplicons"
        },
        {
          "id": "IEAAIKU5JUANE5TN",
          "value": "3 Months"
        }
      ]
    }
  ]
}
```

```bash
call_wrike_api GET tasks/$TASK_ID/attachments
```
```json
{
  "kind": "attachments",
  "data": [
    {
      "id": "IEAAIKU5IYXBA7WO",
      "authorId": "KUAAXTKP",
      "name": "six_samples.tsv",
      "createdDate": "2026-08-26T19:25:47Z",
      "version": 1,
      "type": "Wrike",
      "contentType": "text/tab-separated-values",
      "size": 1044,
      "taskId": "MAAAAAEOud3s",
      "originVersionId": "IEAAIKU5IYXBA7WO"
    }
  ]
}
```

Example webhook payload when that task is DELETED from the Dashboards folder:
```json
{
    "Messages": [
        {
            "MessageId": "c1de2d09-a6f2-4353-b1bb-fd7651e28dfc",
            "ReceiptHandle": "AQEBW5JeB2GIoXFe4jN4cUMNBUiZiUEHlcjJWSbJY3ZoYFjqNO9i3RPl4+EaVhdCDg72Wm/G4GdJ97V8gjJ+7fg+c8Lyz/n+JlQ32NcHi8jPdaQBGT4hD/D/PHM3jt1vfjDvrK834NVixssGahoJTQNFB5w/63w/2S2Y3WNfstfJhdPfPRldhKonQlRtNqab6uIyE6Ih4Qi1OO6ddrTGNZds59bp+GBVcTSzRXJwUsHx89QqcKfciiBJfoabSAmgfVnaLvpR0LguSAx1Z6T/UxKNB2PxxPE5XyDMHMh8F1xe1iLgxKXAbxch27qLTeN7w9A1EPPx7FvgsDo7lWWgSc1/wWe7yjqjIjlezgeXbjUcmgCDCtDWZUKhY8TVOCqK6oon",
            "MD5OfBody": "d490fe0cc8169884d0630e59abb8ce2f",
            "Body": "[\n  {\n    \"taskId\": \"MAAAAAEOCjgR\",\n    \"webhookId\": \"IEAAIKU5JAACF45S\",\n    \"eventAuthorId\": \"KUAAXTKP\",\n    \"eventType\": \"TaskDeleted\",\n    \"lastUpdatedDate\": \"2026-08-11T23:28:21Z\"\n  }\n]"
        }
    ]
}
```




## AWS Lambda Function for wrike-webhook-bridge

Gatekeeper for adding webhook payloads on to the SQS Queue. 
Webhook sender must know our pre-shared key `$WRIKE_WEBHOOK_SECRET`.

```python
import json
import os
import boto3
import hmac
import hashlib
import base64

sqs = boto3.client('sqs', region_name='us-east-1')
AWS_SQS_QUEUE_URL = os.environ.get('AWS_SQS_QUEUE_URL', '')
WRIKE_WEBHOOK_SECRET = os.environ.get('WRIKE_WEBHOOK_SECRET', '')

def lambda_handler(event, context):
    headers = event.get('headers', {}) or {}
    lower_headers = {k.lower(): v for k, v in headers.items()}
    
    raw_body = event.get('body', '') 
    if raw_body is None:
        raw_body = ''

    if not AWS_SQS_QUEUE_URL or not WRIKE_WEBHOOK_SECRET:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Environment variables missing'})
        }

    # Prepare default response headers
    response_headers = {'Content-Type': 'application/json'}

    # 1. Secure Wrike Handshake Verification
    if 'x-hook-secret' in lower_headers:
        challenge = lower_headers['x-hook-secret']
        response_secret = hmac.new(
            WRIKE_WEBHOOK_SECRET.encode('utf-8'),
            challenge.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()
        
        # Attach the calculated secret to our response headers
        response_headers['X-Hook-Secret'] = response_secret
        
        # If there is NO signature, this is purely an initial setup handshake.
        # We can safely exit here.
        if 'x-hook-signature' not in lower_headers:
            return {
                'statusCode': 200,
                'headers': response_headers,
                'body': json.dumps({'status': 'handshake_success'})
            }

    # 2. Verify Signature on actual webhook events
    received_signature = lower_headers.get('x-hook-signature')
    
    if not received_signature:
        return {
            'statusCode': 401,
            'body': json.dumps({'error': 'Missing signature header'})
        }

    # Handle API Gateway base64 encoding
    is_base64 = event.get('isBase64Encoded', False)
    
    try:
        if is_base64:
            actual_body_bytes = base64.b64decode(raw_body)
            string_body = actual_body_bytes.decode('utf-8')
        else:
            actual_body_bytes = raw_body.encode('utf-8')
            string_body = raw_body
    except Exception as e:
        print(f"CRASH DURING DECODING: {str(e)}")
        raise e

    calculated_signature = hmac.new(
        WRIKE_WEBHOOK_SECRET.encode('utf-8'),
        actual_body_bytes,
        hashlib.sha256
    ).hexdigest()
    
    if not hmac.compare_digest(calculated_signature, received_signature.lower()):
        return {
            'statusCode': 403,
            'body': json.dumps({'error': 'Invalid signature'})
        }

    # 3. Webhook Event Processing
    try:
        sqs_kwargs = {
            'QueueUrl': AWS_SQS_QUEUE_URL,
            'MessageBody': string_body
        }
        
        if AWS_SQS_QUEUE_URL.endswith('.fifo'):
            sqs_kwargs['MessageGroupId'] = 'wrike-webhook-events'
            
        sqs.send_message(**sqs_kwargs)
        
    except Exception as e:
        print(f"SQS Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Failed to enqueue message'})
        }
    
    # 4. Return success WITH the handshake headers attached if they were generated
    return {
        'statusCode': 200,
        'headers': response_headers,
        'body': json.dumps({'status': 'message_queued'})
    }
```