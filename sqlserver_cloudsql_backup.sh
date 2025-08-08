#!/bin/bash

# --- SCRIPT SETUP ---
# Source the configuration file to load all global settings
CREDENTIALS_FILE="/backup/configs/sql_credentials.conf"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "ERROR: Credentials file not found at $CREDENTIALS_FILE."
    exit 1
fi
source "$CREDENTIALS_FILE"

# Configuration file for the database list
DB_LIST_FILE="/backup/configs/MSSQL_database_list.conf"
if [ ! -f "$DB_LIST_FILE" ]; then
    echo "ERROR: Database list file not found at $DB_LIST_FILE."
    exit 1
fi

# --- SCRIPT LOGIC ---
echo "Starting database export and compression process to Cloud Storage..."

# Check if gsutil is installed
if ! command -v gsutil &> /dev/null
then
    echo "ERROR: gsutil could not be found. Please ensure Google Cloud SDK is installed and configured."
    exit 1
fi

while IFS=, read -r instance_name host_ip db_name; do
    # Trim any leading/trailing whitespace
    instance_name=$(echo "$instance_name" | xargs)
    db_name=$(echo "$db_name" | xargs)

    # Skip empty or commented lines
    if [[ -z "$db_name" || "$db_name" =~ ^# ]]; then
        continue
    fi

    # Get current timestamp for file naming in yyyy-mm-dd format
    TIMESTAMP=$(date +"%Y-%m-%d")
    
    # Construct the GCS path and file name based on your new naming convention
    GCS_FULL_PATH="$GCS_BASE_PATH/$instance_name/$db_name/FULL"
    UNCOMPRESSED_BACKUP_URL="gs://$GCS_BUCKET_NAME/$GCS_FULL_PATH/${TIMESTAMP}_${db_name}.sql"
    COMPRESSED_BACKUP_URL="gs://$GCS_BUCKET_NAME/$GCS_FULL_PATH/${TIMESTAMP}_${db_name}.sql.gz"

    echo "Exporting database: [$db_name] on instance [$instance_name] to URL: $UNCOMPRESSED_BACKUP_URL"

    # The gcloud command to perform the export
    gcloud sql export sql "$instance_name" "$UNCOMPRESSED_BACKUP_URL" --database="$db_name"

    if [ $? -eq 0 ]; then
        echo "SUCCESS: Export of database [$db_name] completed. Starting compression..."

        # Use gsutil to compress the exported file and store it with the .gz extension
        gsutil cp "$UNCOMPRESSED_BACKUP_URL" "$COMPRESSED_BACKUP_URL"
        if [ $? -eq 0 ]; then
            echo "SUCCESS: Backup file compressed. Deleting uncompressed version."
            # Delete the uncompressed version to save on storage
            gsutil rm "$UNCOMPRESSED_BACKUP_URL"
        else
            echo "ERROR: Failed to compress backup file."
        fi
    else
        echo "ERROR: Export of database [$db_name] failed. Check permissions and logs."
    fi
done < "$DB_LIST_FILE"

echo "Database export and compression script finished."
