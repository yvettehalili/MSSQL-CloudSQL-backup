-- This script must be run by the "sqlserver" user,
-- not a regular user.
-- It creates the credential that SQL Server will use to authenticate with Google Cloud Storage.

-- The correct format for the SECRET is 'ACCESS_KEY:SECRET'.
-- Please use the full HMAC key format below.
-- For example: 'GOOG1ESG36GTDNICM5OPON7LX2BNODFFGJSVNI6JCVCRGCZCN4BFSDAOHZRQA:utxe84c3IRrGtR+gaue3dH/cQBT5/bQLoou5JJop'

-- Replace <YOUR_GCS_BUCKET_NAME>, <YOUR_HMAC_ACCESS_KEY>, and <YOUR_HMAC_SECRET>
-- with the actual values.

CREATE CREDENTIAL [s3://storage.googleapis.com/<YOUR_GCS_BUCKET_NAME>]
WITH
    IDENTITY = 'S3 Access Key',
    SECRET = '<YOUR_HMAC_ACCESS_KEY>:<YOUR_HMAC_SECRET>';
GO

-- This script also ensures the GenBackupUser has the db_backupoperator role
-- on all user databases, which is required for the daily backups.
DECLARE @db_name NVARCHAR(255)
DECLARE @sql NVARCHAR(MAX)

DECLARE db_cursor CURSOR FOR
    SELECT name
    FROM sys.databases
    WHERE name NOT IN ('master', 'tempdb', 'model', 'msdb')
    AND state_desc = 'ONLINE';

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = 'USE [' + @db_name + ']; EXEC sp_addrolemember ''db_backupoperator'', ''GenBackupUser'';';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM db_cursor INTO @db_name;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
GO
