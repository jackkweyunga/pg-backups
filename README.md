# PostgreSQL Disaster Recovery System

Complete PostgreSQL backup and restore solution with automated backups to multiple destinations and an interactive restore tool.

## Table of Contents
- [Quick Start](#quick-start)
- [Backup System](#backup-system)
- [Restore Tool](#restore-tool)
- [Manual Restore](#manual-restore-procedures)
- [Configuration](#configuration)
- [Monitoring](#monitoring)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Deploy Backup Service
```bash
# Copy .env.example to .env and configure
cp .env.example .env
nano .env

# Deploy with docker compose
docker compose up -d
```

### Run Interactive Restore Tool
```bash
docker run --rm -it \
  -v $(pwd)/backups:/backups \
  --network your_postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=yourpassword \
  ghcr.io/jackkweyunga/pg-backups-restore:17-alpine
```

---

## Backup System

### Understanding Backups

Each backup run creates a timestamped folder with three backup types:

```
backups/
└── 20251005_120000/              # Timestamp folder (YYYYMMDD_HHMMSS)
    ├── postgres_cluster.sql.gz   # Full cluster (all DBs + roles)
    ├── postgres_globals.sql.gz   # Only users/roles/permissions
    └── postgres_db_mydb.sql.gz   # Individual databases
```

**Why three types?**
- **Full cluster** - Complete disaster recovery (everything)
- **Globals only** - Restore just users/roles without touching data
- **Individual DBs** - Selective restore of specific databases

### Backup Destinations

Backups are stored in up to 3 locations:

1. **Local** (`/backups` volume) - Fast access, short retention
2. **S3/Spaces** - Cloud storage, medium retention
3. **Remote Server** (rsync) - Off-site backup, long retention

### Daily Operations

**Check backup status:**
```bash
# View logs
docker compose logs -f pg-backup

# List backup folders
ls -lh backups/

# Check last backup
ls -lt backups/ | head -5
```

**Run manual backup:**
```bash
docker compose exec pg-backup /tmp/backup-script.sh
```

**Verify backup integrity:**
```bash
BACKUP_FOLDER="20251005_120000"

for file in backups/${BACKUP_FOLDER}/*.sql.gz; do
    if gunzip -t "$file" 2>/dev/null; then
        echo "✓ $(basename $file)"
    else
        echo "✗ $(basename $file) - CORRUPTED"
    fi
done
```

---

## Restore Tool

### Interactive Mode (Recommended)

The restore tool provides a menu-driven interface for easy recovery:

```bash
docker run --rm -it \
  -v $(pwd)/backups:/backups \
  --network postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=secret \
  ghcr.io/jackkweyunga/pg-backups-restore:17-alpine
```

**Features:**
- ✅ Automatic backup discovery (local/S3/remote)
- ✅ Integrity verification before restore
- ✅ Interactive menus with backup age and size
- ✅ Multiple restore types (cluster/database/globals)
- ✅ Dry-run mode
- ✅ Post-restore verification

**Menu Flow:**
```
Main Menu → Select Source → Choose Backup → Verify Integrity
                                                    ↓
            Verify Results ← Execute Restore ← Select Type
```

### With S3 Access

```bash
docker run --rm -it \
  -v $(pwd)/backups:/backups \
  -v $(pwd)/restore:/restore \
  --network postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=secret \
  -e S3_ENABLED=true \
  -e S3_BUCKET=my-backups \
  -e S3_REGION=fra1 \
  -e S3_ACCESS_KEY=DO801... \
  -e S3_SECRET_KEY=NffZb... \
  -e S3_ENDPOINT=https://my-backups.fra1.digitaloceanspaces.com \
  ghcr.io/jackkweyunga/pg-backups-restore:17-alpine
```

### With Remote Server Access

```bash
docker run --rm -it \
  -v $(pwd)/backups:/backups \
  -v ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro \
  --network postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=secret \
  -e RSYNC_ENABLED=true \
  -e RSYNC_HOST=196.200... \
  -e RSYNC_USER=dani \
  -e RSYNC_PATH=/home/user/test-pg-backups \
  ghcr.io/jackkweyunga/pg-backups-restore:17-alpine
```

### Non-Interactive Mode (Automation)

For scripts or automated recovery:

```bash
docker run --rm \
  -v $(pwd)/backups:/backups \
  --network postgres_network \
  -e PGHOST=postgres-primary \
  -e PGUSER=postgres \
  -e PGPASSWORD=secret \
  -e RESTORE_SOURCE=local \
  -e RESTORE_FOLDER=20251005_120000 \
  -e RESTORE_TYPE=cluster \
  ghcr.io/jackkweyunga/pg-backups-restore:17-alpine
```

**Environment Variables:**
- `RESTORE_SOURCE` - `local`, `s3`, or `remote`
- `RESTORE_FOLDER` - Timestamp folder (e.g., `20251005_120000`)
- `RESTORE_TYPE` - `cluster`, `globals`, or `database`
- `RESTORE_DATABASE` - Database name (if `RESTORE_TYPE=database`)

---

## Manual Restore Procedures

If you prefer manual control over the restore tool:

### Quick Restore Commands

**Restore full cluster:**
```bash
BACKUP_FOLDER="20251005_120000"
gunzip -c backups/${BACKUP_FOLDER}/postgres_cluster.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

**Restore single database:**
```bash
BACKUP_FOLDER="20251005_120000"
DB_NAME="mydb"
gunzip -c backups/${BACKUP_FOLDER}/postgres_db_${DB_NAME}.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

**Restore only users/roles:**
```bash
BACKUP_FOLDER="20251005_120000"
gunzip -c backups/${BACKUP_FOLDER}/postgres_globals.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

### Complete Disaster Recovery

1. **Find latest backup:**
   ```bash
   ls -lht backups/ | head -5
   ```

2. **Stop applications:**
   ```bash
   docker compose stop your-app
   ```

3. **Restore cluster:**
   ```bash
   gunzip -c backups/20251005_120000/postgres_cluster.sql.gz | \
       docker exec -i postgres-primary psql -U postgres
   ```

4. **Verify:**
   ```bash
   docker exec postgres-primary psql -U postgres -c "\l"
   docker exec postgres-primary psql -U postgres -c "\du"
   ```

5. **Restart applications:**
   ```bash
   docker compose start your-app
   ```

### Restore from S3

```bash
BACKUP_FOLDER="20251005_120000"

# Download backup folder
aws s3 sync s3://bucket/postgres-backups/${BACKUP_FOLDER}/ ./restore/ \
    --endpoint-url=https://fra1.digitaloceanspaces.com

# Restore
gunzip -c restore/postgres_cluster.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

### Restore from Remote Server

```bash
BACKUP_FOLDER="20251005_120000"

# Download via rsync
rsync -avz user@server:/backups/postgres/${BACKUP_FOLDER}/ ./restore/

# Restore
gunzip -c restore/postgres_cluster.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

---

## Configuration

All configuration is via environment variables in `.env` file.

### PostgreSQL Connection
```bash
PGHOST=postgres-primary
PGPORT=5432
PGUSER=postgres
PGPASSWORD=devpassword
```

### Backup Schedule
```bash
# Cron format: minute hour day month weekday
BACKUP_SCHEDULE=0 */6 * * *    # Every 6 hours
LOCAL_RETENTION_DAYS=1         # Keep backups for 1 day
```

### S3/Spaces Configuration
```bash
S3_ENABLED=true
S3_BUCKET=your-bucket-name
S3_REGION=fra1
S3_ACCESS_KEY=DO801...
S3_SECRET_KEY=NffZb...
S3_ENDPOINT=https://konekti-backups.fra1.digitaloceanspaces.com
S3_RETENTION_DAYS=7
```

### Remote Server (Rsync)
```bash
RSYNC_ENABLED=true
RSYNC_HOST=196.200.229.166
RSYNC_USER=dani
RSYNC_PORT=22
RSYNC_PATH=/home/dani/test-pg-backups
RSYNC_RETENTION_DAYS=30
```

### Notifications (Rocket.Chat)
```bash
ROCKET_CHAT_ENABLED=true
ROCKET_CHAT_BASE_URL=https://your-rocketchat-server.com
ROCKET_CHAT_USER_ID=your_user_id
ROCKET_CHAT_AUTH_TOKEN=your_auth_token
ROCKET_CHAT_ROOM_ID=your_room_id
```

### Recommended Settings

**Development:**
```bash
BACKUP_SCHEDULE=0 */6 * * *
LOCAL_RETENTION_DAYS=1
S3_RETENTION_DAYS=7
RSYNC_ENABLED=false
```

**Production:**
```bash
BACKUP_SCHEDULE=0 */2 * * *
LOCAL_RETENTION_DAYS=2
S3_RETENTION_DAYS=30
RSYNC_ENABLED=true
RSYNC_RETENTION_DAYS=90
```

---

## Monitoring

### Backup Health Check

```bash
#!/bin/bash
# check-backups.sh

LATEST=$(ls -t backups/20* 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
    echo "❌ No backups found!"
    exit 1
fi

# Get folder modification time
BACKUP_TIME=$(stat -c %Y "backups/$LATEST" 2>/dev/null || stat -f %m "backups/$LATEST")
CURRENT_TIME=$(date +%s)
AGE_HOURS=$(( ($CURRENT_TIME - $BACKUP_TIME) / 3600 ))

if [ $AGE_HOURS -gt 12 ]; then
    echo "⚠️  Last backup is $AGE_HOURS hours old"
    exit 1
else
    echo "✅ Backup healthy (last: $AGE_HOURS hours ago)"
fi
```

### Storage Usage

```bash
# Local storage
du -sh backups/
ls -lh backups/ | wc -l

# S3 usage
aws s3 ls s3://bucket/postgres-backups/ --endpoint-url=https://endpoint.com --recursive --summarize

# Remote storage
ssh user@server "du -sh /backups/postgres/"
```

### View Logs

```bash
# Real-time logs
docker compose logs -f pg-backup

# Last 100 lines
docker compose logs --tail=100 pg-backup

# Check for errors
docker compose logs pg-backup | grep -i error
```

---

## Testing

### Automated Restore Testing

The system includes an automated restore test tool that validates backups by performing actual restores in isolated test containers.

**Run manually:**
```bash
./restore-test.sh
```

**Run with Docker (scheduled):**
```yaml
# docker-compose.yml
pg-restore-test:
  image: ghcr.io/jackkweyunga/pg-backups-restore-test:17-alpine
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ./backups:/backups:ro
    - ./restore-test-logs:/restore-test-logs
  environment:
    - TEST_SCHEDULE=0 0 1 * *  # Monthly on 1st at midnight
```

**What it does:**
1. Finds latest backup folder
2. Creates isolated test container (PostgreSQL + PostGIS)
3. Restores full cluster backup
4. Verifies databases and roles
5. Cleans up test container
6. Logs results to timestamped file

**Check test results:**
```bash
# View latest test log
ls -lt restore-test-logs/ | head -1

# Check for errors
grep -i error restore-test-logs/restore-test_*.log | grep -v "already exists" | grep -v "cannot be dropped"

# View full log
cat restore-test-logs/restore-test_20251006_120000.log
```

**Log files:**
```
restore-test-logs/
├── restore-test_20251006_120000.log
├── restore-test_20251006_150000.log
└── restore-test_20251007_120000.log
```

### Monthly Restore Test (Manual Script)

For reference, the restore test script:

```bash
#!/bin/bash
# restore-test.sh

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="restore-test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/restore-test_${TIMESTAMP}.log"

BACKUP_FOLDER=$(ls -t backups/ | head -1)

echo "Testing restore of backup: $BACKUP_FOLDER" | tee -a "$LOG_FILE"

# Create test container (with PostGIS if needed)
docker run -d --name postgres-test \
    -e POSTGRES_PASSWORD=test \
    postgis/postgis:17-3.5

sleep 5

# Restore
gunzip -c backups/${BACKUP_FOLDER}/postgres_cluster.sql.gz | \
    docker exec -i postgres-test psql -U postgres 2>&1 | tee -a "$LOG_FILE"

# Verify
echo "Databases:" | tee -a "$LOG_FILE"
docker exec postgres-test psql -U postgres -c "\l" | tee -a "$LOG_FILE"

echo -e "\nRoles:" | tee -a "$LOG_FILE"
docker exec postgres-test psql -U postgres -c "\du" | tee -a "$LOG_FILE"

# Cleanup
docker rm -f postgres-test

echo "✓ Restore test completed successfully" | tee -a "$LOG_FILE"
```

### Backup Integrity Check

```bash
# Test all backups in latest folder
BACKUP_FOLDER=$(ls -t backups/ | head -1)

for file in backups/${BACKUP_FOLDER}/*.sql.gz; do
    if gunzip -t "$file" 2>/dev/null; then
        echo "✓ $(basename $file)"
    else
        echo "✗ $(basename $file) - CORRUPTED"
    fi
done
```

---

## Troubleshooting

### Backup Issues

| Problem | Solution |
|---------|----------|
| No backups created | Check logs: `docker compose logs pg-backup` |
| S3 upload fails | Verify credentials and bucket access |
| Rsync fails | Test SSH: `ssh user@server` |
| Container restarts | Check restart policy in docker-compose.yml |
| Disk full | Reduce retention days or increase disk space |

### Restore Issues

| Problem | Solution |
|---------|----------|
| "role does not exist" | Restore globals first, then database |
| "database already exists" | Drop database first or restore to different name |
| Backup corrupted | Download from S3/remote, test with `gunzip -t` |
| Restore too slow | Disable fsync temporarily (test only) |
| Connection refused | Check PostgreSQL is running, verify network |

### Common Restore Errors

**Error: "role does not exist"**
```bash
# Restore globals first
gunzip -c backups/${BACKUP_FOLDER}/postgres_globals.sql.gz | \
    docker exec -i postgres-primary psql -U postgres

# Then restore database
gunzip -c backups/${BACKUP_FOLDER}/postgres_db_mydb.sql.gz | \
    docker exec -i postgres-primary psql -U postgres
```

**Error: "database already exists"**
```bash
# Drop database first
docker exec postgres-primary psql -U postgres -c "DROP DATABASE IF EXISTS mydb;"
```

**Backup file corrupted**
```bash
# Test integrity
gunzip -t backups/${BACKUP_FOLDER}/postgres_cluster.sql.gz

# If corrupted, try S3
aws s3 sync s3://bucket/postgres-backups/${BACKUP_FOLDER}/ ./restore/ \
    --endpoint-url=https://endpoint.com
```

---

## Recovery Time Estimates

Based on 1GB database:

| Scenario | Time | Notes |
|----------|------|-------|
| Local restore (manual) | 2-3 min | Direct decompress + restore |
| Local restore (tool) | 3-4 min | Includes verification |
| S3 restore | 5-10 min | Download + decompress + restore |
| Remote restore | 10-15 min | Download + decompress + restore |
| Fresh server setup | 20-30 min | Install Docker + setup + restore |

---

## Security

### Rotate S3 Credentials

```bash
# 1. Generate new keys in DigitalOcean
# 2. Update .env
nano .env

# 3. Restart service
docker compose restart pg-backup

# 4. Revoke old keys
```

### Rotate SSH Keys

```bash
# Generate new key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/pg_backup_new -N ""

# Copy to remote
ssh-copy-id -i ~/.ssh/pg_backup_new.pub user@server

# Test
ssh -i ~/.ssh/pg_backup_new user@server

# Update volume mount in docker-compose.yml
# Restart service
docker compose restart pg-backup
```

---

## Best Practices

### Backups

✅ **DO:**
- Test backups monthly
- Keep 3 copies (local, S3, remote) - 3-2-1 rule
- Verify integrity after each backup
- Monitor backup age and size
- Document your backup schedule
- Use appropriate retention periods

❌ **DON'T:**
- Rely on single backup location
- Delete old backups without verifying new ones
- Ignore backup failures
- Skip regular testing
- Store backups on same server as database

### Restores

✅ **DO:**
- Test in non-production first
- Stop applications before major restores
- Verify backup integrity before restore
- Document restore procedures
- Time your restores (know your RTO)
- Keep restore tool image updated

❌ **DON'T:**
- Restore to production without testing
- Skip verification after restore
- Panic during recovery
- Forget to restart applications
- Skip documentation

---

## Recovery Checklist

Use during actual disaster recovery:

- [ ] Stay calm, don't rush
- [ ] Identify what needs restoring
- [ ] Find appropriate backup folder
- [ ] Test backup integrity (`gunzip -t`)
- [ ] Stop affected applications
- [ ] Choose restore method (tool vs manual)
- [ ] Perform restore
- [ ] Verify databases (`\l`)
- [ ] Verify table data (`SELECT COUNT(*)`)
- [ ] Test application connectivity
- [ ] Restart applications
- [ ] Monitor for issues (30+ minutes)
- [ ] Document incident and timeline

---

## Architecture

### File Structure

```
pg-backups/
├── backup-script.sh                    # Main backup logic
├── backup-cron.sh                      # Cron wrapper
├── restore-tool.sh                     # Interactive restore CLI
├── restore-test.sh                     # Automated restore test
├── lib/                                # Helper libraries
│   ├── backup-discovery.sh             # Find backups
│   ├── backup-download.sh              # Download from S3/remote
│   └── restore-executor.sh             # Execute restores
├── Dockerfile.backup-17-alpine         # Backup service image
├── Dockerfile.restore-17-alpine        # Restore tool image
├── Dockerfile.restore-test-17-alpine   # Restore test image
├── docker-compose.yml                  # Service definition
├── .env.example                        # Configuration template
├── backups/                            # Local backup storage
│   └── YYYYMMDD_HHMMSS/                # Timestamped folders
└── restore-test-logs/                  # Test results
    └── restore-test_YYYYMMDD_HHMMSS.log
```

### Docker Images

Three Docker images built via GitHub Actions matrix for multiple PostgreSQL versions:

1. **Backup Image** - `ghcr.io/jackkweyunga/pg-backups:17-alpine`
   - Automated scheduled backups with cron
   - Supports S3, remote sync, notifications

2. **Restore Image** - `ghcr.io/jackkweyunga/pg-backups-restore:17-alpine`
   - Interactive CLI for backup restoration
   - Supports local, S3, remote sources

3. **Restore Test Image** - `ghcr.io/jackkweyunga/pg-backups-restore-test:17-alpine`
   - Monthly automated restore validation
   - Creates test containers and verifies backups

**GitHub Actions Matrix:**
Workflow builds for PostgreSQL versions defined in matrix:
- `17-alpine`
- `18-alpine`

To add more versions, edit `.github/workflows/docker-publish.yml` matrix.

**Manual Build:**
```bash
# Build with custom PostgreSQL version
docker build --build-arg POSTGRES_TAG=18.0-latest -f Dockerfile.backup -t pg-backups:18 .
```

---

## Monthly Checklist

- [ ] Run restore test (automated via restore-test image)
- [ ] Review restore test logs in `restore-test-logs/`
- [ ] Verify all backup destinations (local/S3/remote)
- [ ] Check backup logs for errors
- [ ] Verify backup file integrity
- [ ] Review storage usage and costs
- [ ] Test restore speed (time it)
- [ ] Update documentation if needed
- [ ] Rotate credentials (quarterly)
- [ ] Review and adjust retention periods
- [ ] Test restore tool with latest backup

---

## Support

**Need help during recovery?**
- Don't panic
- Follow the recovery checklist
- Test in separate container first
- Check troubleshooting section
- Review logs for specific errors

**Backup Locations:**
- Local: `./backups/`
- S3: `s3://your-bucket/postgres-backups/`
- Remote: `user@server:/backups/postgres/`

**Key Containers:**
- PostgreSQL: `postgres-primary`
- Backup: `pg-backup`
