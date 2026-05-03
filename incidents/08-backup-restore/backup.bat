@echo off
SET DB_NAME=%1
SET BACKUP_DIR=incidents\08-backup-restore\backups

IF "%DB_NAME%"=="" (
    SET DB_NAME=warroom
    echo WARNING: No database specified. Defaulting to warroom.
)

SET TIMESTAMP=%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%
SET TIMESTAMP=%TIMESTAMP: =0%
SET BACKUP_FILE=%BACKUP_DIR%\%DB_NAME%_%TIMESTAMP%.dump
SET SCHEMA_FILE=%BACKUP_DIR%\%DB_NAME%_%TIMESTAMP%_schema.sql
SET VERIFY_FILE=%BACKUP_DIR%\%DB_NAME%_%TIMESTAMP%_verify.txt

IF NOT EXIST "%BACKUP_DIR%" (
    mkdir "%BACKUP_DIR%"
    echo Created backup directory: %BACKUP_DIR%
)

echo ============================================================
echo  PostgreSQL Backup Utility
echo  TimescaleDB-Compatible
echo ============================================================
echo  Database:    %DB_NAME%
echo  Backup file: %BACKUP_FILE%
echo  Schema file: %SCHEMA_FILE%
echo  Started at:  %DATE% %TIME%
echo ============================================================
echo.

echo [Step 1/4] Running full database backup...
pg_dump -h localhost -p 5433 -U postgres -d %DB_NAME% ^
    -F c ^
    --no-acl ^
    --no-owner ^
    -f %BACKUP_FILE% ^
    -v

IF %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Backup failed. Check connection and database name.
    exit /b 1
)

echo.
echo [Step 2/4] Running schema-only backup for documentation...
pg_dump -h localhost -p 5433 -U postgres -d %DB_NAME% ^
    -F p ^
    --schema-only ^
    --no-acl ^
    --no-owner ^
    -f %SCHEMA_FILE%

echo.
echo [Step 3/4] Verifying backup file is readable...
pg_restore -l %BACKUP_FILE% > %VERIFY_FILE%

IF %ERRORLEVEL% NEQ 0 (
    echo ERROR: Backup file is not readable. Backup may be corrupt.
    exit /b 1
)

echo Backup contents saved to: %VERIFY_FILE%

echo.
echo [Step 4/4] Capturing row counts for verification after restore...
psql -h localhost -p 5433 -U postgres -d %DB_NAME% -c ^
    "SELECT tablename AS table_name, ^
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size ^
     FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;" ^
    >> %VERIFY_FILE%

psql -h localhost -p 5433 -U postgres -d %DB_NAME% -c ^
    "SELECT 'order_events' AS table_name, COUNT(*) FROM order_events ^
     UNION ALL SELECT 'customers', COUNT(*) FROM customers ^
     UNION ALL SELECT 'products', COUNT(*) FROM products ^
     UNION ALL SELECT 'product_embeddings', COUNT(*) FROM product_embeddings ^
     UNION ALL SELECT 'order_events_archive', COUNT(*) FROM order_events_archive ^
     UNION ALL SELECT 'order_events_audit', COUNT(*) FROM order_events_audit;" ^
    >> %VERIFY_FILE%

echo.
echo ============================================================
echo  Backup Summary
echo ============================================================
echo  Full dump:   %BACKUP_FILE%
echo  Schema dump: %SCHEMA_FILE%
echo  Verify file: %VERIFY_FILE%
echo  Completed:   %DATE% %TIME%
echo.
echo  IMPORTANT NOTES FOR TIMESCALEDB RESTORE:
echo  1. Always enable TimescaleDB extension before restoring
echo  2. Always restore schema first, then data separately
echo  3. Use --data-only --disable-triggers for data restore
echo  4. Verify row counts after restore using %VERIFY_FILE%
echo  5. Check chunks if hypertable shows COUNT = 0
echo ============================================================
dir %BACKUP_FILE%