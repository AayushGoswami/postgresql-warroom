@echo off
SET TABLE_NAME=%1
SET BACKUP_FILE=%2
SET TARGET_DB=%3

IF "%TABLE_NAME%"=="" (
    echo ERROR: Table name is required.
    echo.
    echo Usage:   restore_table.bat [table_name] [backup_file] [target_database]
    echo Example: restore_table.bat product_embeddings backups\warroom_full.dump warroom
    echo.
    echo Notes:
    echo   - Target database must already exist
    echo   - TimescaleDB extension must be enabled in target database before running
    echo   - For hypertables, all counts must be verified after restore
    exit /b 1
)

IF "%BACKUP_FILE%"=="" (
    echo ERROR: Backup file path is required.
    echo Usage: restore_table.bat [table_name] [backup_file] [target_database]
    exit /b 1
)

IF "%TARGET_DB%"=="" (
    SET TARGET_DB=warroom
    echo WARNING: No target database specified. Defaulting to warroom.
)

IF NOT EXIST "%BACKUP_FILE%" (
    echo ERROR: Backup file not found: %BACKUP_FILE%
    exit /b 1
)

echo ============================================================
echo  PostgreSQL Table Restore Utility
echo  TimescaleDB-Compatible
echo ============================================================
echo  Table:    %TABLE_NAME%
echo  Backup:   %BACKUP_FILE%
echo  Database: %TARGET_DB%
echo ============================================================
echo.

echo [Step 1/3] Restoring schema for table: %TABLE_NAME%
pg_restore -h localhost -p 5433 -U postgres -d %TARGET_DB% ^
    -t %TABLE_NAME% ^
    --schema-only ^
    --no-acl ^
    --no-owner ^
    -v ^
    %BACKUP_FILE%

echo.
echo [Step 2/3] Restoring data for table: %TABLE_NAME%
pg_restore -h localhost -p 5433 -U postgres -d %TARGET_DB% ^
    -t %TABLE_NAME% ^
    --data-only ^
    --disable-triggers ^
    --no-acl ^
    --no-owner ^
    -v ^
    %BACKUP_FILE%

echo.
echo [Step 3/3] Verifying row count...
psql -h localhost -p 5433 -U postgres -d %TARGET_DB% -c ^
    "SELECT '%TABLE_NAME%' AS table_name, COUNT(*) AS restored_rows FROM %TABLE_NAME%;"

echo.
echo ============================================================
echo  Restore complete.
echo  IMPORTANT: Verify the row count above matches your original.
echo  If count is 0 for a hypertable, chunks may be empty.
echo  Run: SELECT chunk_name FROM timescaledb_information.chunks
echo       WHERE hypertable_name = '%TABLE_NAME%';
echo ============================================================