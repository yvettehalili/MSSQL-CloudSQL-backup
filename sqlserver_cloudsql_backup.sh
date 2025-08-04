#!/bin/bash

# --- SCRIPT SETUP ---
# Source the configuration file to load all credentials and global settings
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

# Check if sqlcmd is installed
if ! command -v sqlcmd &> /dev/null
then
    echo "ERROR: sqlcmd could not be found. Please install mssql-tools."
    exit 1
fi

# --- STEP 1: CREATE OR UPDATE THE SQL SERVER CREDENTIAL FOR GCS ---
# This step still needs a single, static connection to create the credential.
# For simplicity and to avoid creating a credential per instance, we'll use the IP from the first line of the config file.
echo "Checking for and creating/updating SQL Server credential for GCS..."
FIRST_HOST_IP=$(head -n 1 "$DB_LIST_FILE" | awk -F, '{print $2}' | xargs)
CONNECTION_STRING="sqlcmd -S tcp:$FIRST_HOST_IP,$SQL_SERVER_PORT -U \"$SQL_SERVER_USER\" -P \"$SQL_SERVER_PASSWORD\""
SQL_CREDENTIAL_QUERY="
IF NOT EXISTS (SELECT * FROM sys.credentials WHERE name = '$SQL_CREDENTIAL_NAME')
    CREATE CREDENTIAL [$SQL_CREDENTIAL_NAME] WITH IDENTITY = 'S3 Access Key', SECRET = '$HMAC_SECRET';
ELSE
    ALTER CREDENTIAL [$SQL_CREDENTIAL_NAME] WITH IDENTITY = 'S3 Access Key', SECRET = '$HMAC_SECRET';
GO
"
echo "$SQL_CREDENTIAL_QUERY" | $CONNECTION_STRING
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create or update the SQL Server credential. Check your HMAC keys and permissions."
    exit 1
fi
echo "SQL Server credential setup complete."

# --- STEP 2: LOOP THROUGH DATABASES AND PERFORM BACKUPS ---
echo "Starting full database backup process..."

while IFS=, read -r instance_name host_ip db_name; do
  # Trim any leading/trailing whitespace
  instance_name=$(echo "$instance_name" | xargs)
  host_ip=$(echo "$host_ip" | xargs)
  db_name=$(echo "$db_name" | xargs)

  # Skip empty or commented lines
  if [[ -z "$db_name" || "$db_name" =~ ^# ]]; then
    continue
  fi

  # Define the connection string dynamically for each database/host
  CONNECTION_STRING="sqlcmd -S tcp:$host_ip,$SQL_SERVER_PORT -U \"$SQL_SERVER_USER\" -P \"$SQL_SERVER_PASSWORD\""
  
  # Get current timestamp for file naming
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  
  # Construct the GCS path and file name based on your naming convention
  GCS_FULL_PATH="$GCS_BASE_PATH/$instance_name/$db_name/FULL"
  BACKUP_FILE_NAME="${instance_name}_${db_name}_FULL_$TIMESTAMP.bak"
  BACKUP_URL="s3://storage.googleapis.com/$GCS_BUCKET_NAME/$GCS_FULL_PATH/$BACKUP_FILE_NAME"

  echo "Backing up database: [$db_name] on instance [$instance_name] to URL: $BACKUP_URL"

  # The BACKUP DATABASE command
  BACKUP_QUERY="BACKUP DATABASE [$db_name] TO URL = N'$BACKUP_URL' WITH COMPRESSION, STATS = 10, CHECKSUM, FORMAT; GO"
  
  # Execute the backup
  echo "$BACKUP_QUERY" | $CONNECTION_STRING
  
  if [ $? -eq 0 ]; then
    echo "SUCCESS: Backup of database [$db_name] completed."
  else
    echo "ERROR: Backup of database [$db_name] failed. Check SQL Server logs for details."
  fi

done < "$DB_LIST_FILE"

echo "Database backup script finished."
