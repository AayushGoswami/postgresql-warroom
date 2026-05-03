# Incident 08 — Backup, Restore & Migration

## Symptoms
Customer accidentally dropped a critical table in production.
Customer is requesting data recovery from last known backup.
Alternatively — customer planning a database migration and needs
a reliable backup/restore strategy before proceeding.

## Environment
- Database: PostgreSQL 18 + TimescaleDB
- Tool: pg_dump / pg_restore (built-in PostgreSQL utilities)
- Backup format: Custom (-F c) — compressed, supports selective restore

## Pre-Backup Inventory
Before any backup, always document exact row counts:

| Table | Row Count | Size |
|---|---|---|
| order_events | 145517 | 64 kB |
| customers | 500 | 168 kB |
| products | 100 | 32 kB |
| product_embeddings | 10000 | 15 MB |
| order_events_archive | 57532 | 12 MB |
| bloat_test | 100000 | 13 MB |

## Backup Procedure

### Full database backup (recommended format)
```cmd
pg_dump -h localhost -p 5433 -U postgres -d warroom -F c -f warroom_full.dump -v
```

### Schema-only backup (for documentation)
```cmd
pg_dump -h localhost -p 5433 -U postgres -d warroom -F p --schema-only -f warroom_schema.sql
```

### Backup file details
- Full dump size: [your file size]
- Backup duration: [your time]
- Format: Custom (compressed)

## Restore Procedures

### Inspect backup contents before restoring
```cmd
pg_restore -l warroom_full.dump
```
Always run this first — confirms what is in the backup
before committing to a restore.

### Partial restore — single table only
```cmd
pg_restore -h localhost -p 5433 -U postgres -d warroom -t [table_name] -v warroom_full.dump
```
Critical capability — restore one table without affecting
any other tables in the database. Used when a customer
accidentally drops or corrupts a single table.

### Full database restore into new database
```cmd
pg_restore -h localhost -p 5433 -U postgres -d warroom_restored -F c -v warroom_full.dump
```

## Disaster Simulation & Recovery Results

### Simulated disaster
- Dropped tables: product_embeddings, bloat_test
- Method: DROP TABLE CASCADE

### Recovery
- product_embeddings: restored 10000 rows verified
- bloat_test: restored 100000 rows verified
- All row counts matched pre-backup inventory exactly

## Real Issue Encountered During Restore

### Problem
Running pg_restore with default flags produced two issues:
1. FK constraint errors due to ONLY keyword incompatibility
   with TimescaleDB hypertables
2. Chunk data was created but rows were never loaded —
   all tables showed COUNT(*) = 0 despite chunks existing

### Root Cause
The FK errors caused pg_restore to skip TABLE DATA sections
for the internal chunk tables, leaving all chunks empty.

### Final Working Restore Procedure

Step 1 — Create database and enable extensions first:
    CREATE EXTENSION IF NOT EXISTS timescaledb;
    CREATE EXTENSION IF NOT EXISTS vector;

Step 2 — Restore schema only first:
    pg_restore ... --schema-only

Step 3 — Restore data only with triggers disabled:
    pg_restore ... --data-only --disable-triggers

Step 4 — Manually add FK constraints without ONLY keyword

Step 5 — Verify row counts match original exactly

### Lesson
Never assume a restore succeeded without verifying row counts.
Always test restore procedure before a real disaster happens.


## Pre-Migration Checklist
Before any database migration, always:
1. Run a full pg_dump backup and verify file size is non-zero
2. Run pg_restore -l to confirm backup is readable
3. Document all row counts using the inventory query
4. Test restore into a separate database first
5. Verify row counts match after test restore
6. Only proceed with migration after all above pass

## Important Notes on TimescaleDB Backups
- pg_dump works on TimescaleDB databases but may show warnings
  about TimescaleDB-internal tables — these are expected and safe
- For production TimescaleDB, also consider timescaledb-backup
  utility for chunk-aware backups
- Compressed chunks are backed up in their compressed state —
  backup files are smaller when compression is enabled
- Always restore into a database with TimescaleDB pre-installed
  and the extension created before running pg_restore

## Reusable Scripts
- backup.bat [database_name] — timestamped automated backup script
- restore_table.bat [table_name] [backup_file] [target_database] — single table restore utility

## Key Commands Reference
```cmd
-- Full backup
pg_dump -h localhost -p 5433 -U postgres -d warroom -F c -f backup.dump

-- List backup contents
pg_restore -l backup.dump

-- Restore single table
pg_restore -h localhost -p 5433 -U postgres -d warroom -t table_name backup.dump

-- Full restore to new database
pg_restore -h localhost -p 5433 -U postgres -d new_db -F c backup.dump
```