import base64
import json
import os
import pg8000
from google.cloud import secretmanager

def get_secret(secret_name):
    client = secretmanager.SecretManagerServiceClient()
    project_id = os.environ.get("GCP_PROJECT")
    name = f"projects/{project_id}/secrets/{secret_name}/versions/latest"
    response = client.access_secret_version(name=name)
    return response.payload.data.decode("UTF-8")

def process_event(event, context):
    message = base64.b64decode(event['data']).decode('utf-8')
    data = json.loads(message)

    bucket = data['bucket']
    name = data['name']

    print(f"Processing {name} from {bucket}")

    try:
        password = get_secret("db-password")

        conn = pg8000.connect(
            user=os.environ.get("DB_USER"),
            password=password,
            host=os.environ.get("DB_HOST"),
            database=os.environ.get("DB_NAME")
        )

        cursor = conn.cursor()
        cursor.execute(
            "CREATE TABLE IF NOT EXISTS events (id SERIAL PRIMARY KEY, bucket_name TEXT, file_name TEXT);"
        )
        cursor.execute(
            "INSERT INTO events (bucket_name, file_name) VALUES (%s, %s);",
            (bucket, name)
        )

        conn.commit()
        cursor.close()
        conn.close()

        print("Inserted successfully")

    except Exception as e:
        print("Error:", e)