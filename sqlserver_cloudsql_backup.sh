#!/bin/bash

# --- SCRIPT SETUP ---
CREDENTIALS_FILE="/backup/configs/sql_credentials.conf"
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "ERROR: Credentials file not found at $CREDENTIALS_FILE."
    exit 1
fi
source "$CREDENTIALS_FILE"

DB_LIST_FILE="/backup/configs/MSSQL_database_list.conf"
if [ ! -f "$DB_LIST_FILE" ]; then
    echo "ERROR: Database list file not found at $DB_LIST_FILE."
    exit 1
fi

# --- SCRIPT LOGIC ---
if ! command -v sqlcmd &> /dev/null
then
    echo "ERROR: sqlcmd could not be found. Please install mssql-tools."
    exit 1
fi

# Get the IP of the first instance to create the credential
FIRST_HOST_IP=$(head -n 1 "$DB_LIST_FILE" | awk -F, '{print $2}' | xargs)
if [ -z "$FIRST_HOST_IP" ]; then
    echo "ERROR: Database list file is empty or formatted incorrectly."
    exit 1
fi

# --- STEP 1: CREATE OR UPDATE THE SQL SERVER CREDENTIAL FOR GCS ---
echo "Checking for and creating/updating SQL Server credential for GCS..."
SQL_CREDENTIAL_QUERY="
IF NOT EXISTS (SELECT * FROM sys.credentials WHERE name = '$SQL_CREDENTIAL_NAME')
    CREATE CREDENTIAL [$SQL_CREDENTIAL_NAME] WITH IDENTITY = 'S3 Access Key', SECRET = '$HMAC_SECRET';
ELSE
    ALTER CREDENTIAL [$SQL_CREDENTIAL_NAME] WITH IDENTITY = 'S3 Access Key', SECRET = '$HMAC_SECRET';
GO
"
# Use a temp file to pass the query to sqlcmd securely
echo "$SQL_CREDENTIAL_QUERY" > /tmp/credential_query.sql
sqlcmd -S tcp:"$FIRST_HOST_IP","$SQL_SERVER_PORT" -U "$SQL_SERVER_USER" -P "$SQL_SERVER_PASSWORD" -i /tmp/credential_query.sql
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create or update the SQL Server credential. Check your HMAC keys and permissions."
    rm /tmp/credential_query.sql
    exit 1
fi
echo "SQL Server credential setup complete."
rm /tmp/credential_query.sql

# --- STEP 2: LOOP THROUGH DATABASES AND PERFORM BACKUPS ---
echo "Starting full database backup process..."

while IFS=, read -r instance_name host_ip db_name; do
  instance_name=$(echo "$instance_name" | xargs)
  host_ip=$(echo "$host_ip" | xargs)
  db_name=$(echo "$db_name" | xargs)

  if [[ -z "$db_name" || "$db_name" =~ ^# ]]; then
    continue
  fi

  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  GCS_FULL_PATH="$GCS_BASE_PATH/$instance_name/$db_name/FULL"
  BACKUP_FILE_NAME="${instance_name}_${db_name}_FULL_$TIMESTAMP.bak"
  BACKUP_URL="s3://storage.googleapis.com/$GCS_BUCKET_NAME/$GCS_FULL_PATH/$BACKUP_FILE_NAME"

  echo "Backing up database: [$db_name] on instance [$instance_name] to URL: $BACKUP_URL"

  BACKUP_QUERY="BACKUP DATABASE [$db_name] TO URL = N'$BACKUP_URL' WITH COMPRESSION, STATS = 10, CHECKSUM, FORMAT; GO"
  
  # Use a temp file to pass the query securely
  echo "$BACKUP_QUERY" > /tmp/backup_query.sql
  sqlcmd -S tcp:"$host_ip","$SQL_SERVER_PORT" -U "$SQL_SERVER_USER" -P "$SQL_SERVER_PASSWORD" -i /tmp/backup_query.sql
  
  if [ $? -eq 0 ]; then
    echo "SUCCESS: Backup of database [$db_name] completed."
  else
    echo "ERROR: Backup of database [$db_name] failed. Check SQL Server logs for details."
  fi
  rm /tmp/backup_query.sql
done < "$DB_LIST_FILE"

echo "Database backup script finished."
