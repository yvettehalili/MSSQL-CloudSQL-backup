#!/bin/bash

# --- SCRIPT SETUP ---
# Source the configuration file to load all variables
CREDENTIALS_FILE="/backup/configs/sql_credentials.conf"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Credentials file not found at $CREDENTIALS_FILE."
    exit 1
fi
source "$CREDENTIALS_FILE"

# Configuration file for the database list
DB_LIST_FILE="/backup/configs/MSSQL_database_list.conf"
if [ ! -f "$DB_LIST_FILE" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Database list file not found at $DB_LIST_FILE."
    exit 1
fi

# --- SCRIPT LOGIC ---
echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Starting native .bak backup process to Cloud Storage..."

# Check if gcloud is installed and the key file exists
if ! command -v gcloud &> /dev/null
then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] gcloud command not found. Please ensure Google Cloud SDK is installed and authenticated."
    exit 1
fi

if [ ! -f "$SERVICE_ACCOUNT_KEY_FILE" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Service account key file not found at '$SERVICE_ACCOUNT_KEY_FILE'."
    exit 1
fi

# Activate the service account using the key file
echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Authenticating with service account..."
gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_KEY_FILE"
if [ $? -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to authenticate with the service account. Check the key file and permissions."
    exit 1
fi
echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Authentication successful."

while IFS=, read -r instance_name host_ip db_name project_id; do
    # Trim any leading/trailing whitespace
    instance_name=$(echo "$instance_name" | xargs)
    db_name=$(echo "$db_name" | xargs)
    project_id=$(echo "$project_id" | xargs)

    # Skip empty or commented lines
    if [[ -z "$db_name" || "$db_name" =~ ^# ]]; then
        continue
    fi
    
    # Check if project_id is provided
    if [ -z "$project_id" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Missing project_id for database [$db_name]. Skipping."
        continue
    fi

    # Get current timestamp for file naming
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

    # Construct the GCS URL for the native .bak backup file
    BACKUP_URL="gs://$GCS_BUCKET_NAME/$GCS_BASE_PATH/$instance_name/$db_name/FULL/${instance_name}_${db_name}_FULL_$TIMESTAMP.bak"

    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Backing up database: [$db_name] on instance [$instance_name] to URL: $BACKUP_URL"

    # The gcloud command to perform the native .bak backup with the project flag from the config file
    gcloud sql export bak "$instance_name" "$BACKUP_URL" --database="$db_name" --project="$project_id" --quiet

    if [ $? -eq 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') [SUCCESS] Native .bak backup of database [$db_name] completed."
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Native .bak backup of database [$db_name] failed. Check IAM permissions and logs."
    fi
done < "$DB_LIST_FILE"

echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Database backup script finished."
