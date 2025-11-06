#!/bin/bash
set -e

# PostgreSQL Disaster Recovery Backup Script
# Creates full cluster backup + individual database backups
# Uploads to S3 and/or syncs to remote server

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_BASE_DIR="/backups"
BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
LOCAL_RETENTION=${LOCAL_RETENTION_DAYS:-1}

# S3 Configuration
S3_ENABLED=${S3_ENABLED:-false}
S3_RETENTION=${S3_RETENTION_DAYS:-7}

# Rsync Configuration
RSYNC_ENABLED=${RSYNC_ENABLED:-false}
RSYNC_RETENTION=${RSYNC_RETENTION_DAYS:-30}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

log "=== PostgreSQL Backup Started ==="
log "Host: $PGHOST:$PGPORT"
log "User: $PGUSER"

# =============================================================================
# 1. FULL CLUSTER BACKUP (pg_dumpall - everything)
# =============================================================================
CLUSTER_BACKUP="${BACKUP_DIR}/postgres_cluster.sql.gz"
log "Creating full cluster backup..."

if pg_dumpall \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --verbose \
    --clean \
    --if-exists \
    | gzip > "$CLUSTER_BACKUP"; then
    
    CLUSTER_SIZE=$(du -h "$CLUSTER_BACKUP" | cut -f1)
    log "✓ Full cluster backup completed: $CLUSTER_BACKUP ($CLUSTER_SIZE)"
else
    log "✗ ERROR: Full cluster backup failed!"
    exit 1
fi

# =============================================================================
# 2. GLOBALS BACKUP (roles, tablespaces only)
# =============================================================================
GLOBALS_BACKUP="${BACKUP_DIR}/postgres_globals.sql.gz"
log "Creating globals backup..."

if pg_dumpall \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --globals-only \
    --verbose \
    | gzip > "$GLOBALS_BACKUP"; then
    
    GLOBALS_SIZE=$(du -h "$GLOBALS_BACKUP" | cut -f1)
    log "✓ Globals backup completed: $GLOBALS_BACKUP ($GLOBALS_SIZE)"
else
    log "✗ ERROR: Globals backup failed!"
    exit 1
fi

# =============================================================================
# 3. INDIVIDUAL DATABASE BACKUPS
# =============================================================================
log "Discovering databases..."

# Get list of databases, excluding templates
DATABASES=$(psql \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="postgres" \
    --tuples-only \
    --no-align \
    --command="SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    | grep -v "^$")

if [ -z "$DATABASES" ]; then
    log "⚠ No user databases found to backup"
else
    log "Found databases: $(echo $DATABASES | tr '\n' ' ')"
    
    for DB in $DATABASES; do
        DB_BACKUP="${BACKUP_DIR}/postgres_db_${DB}.sql.gz"
        log "Backing up database: $DB"
        
        if pg_dump \
            --host="$PGHOST" \
            --port="$PGPORT" \
            --username="$PGUSER" \
            --dbname="$DB" \
            --verbose \
            --clean \
            --if-exists \
            --create \
            --format=plain \
            | gzip > "$DB_BACKUP"; then
            
            DB_SIZE=$(du -h "$DB_BACKUP" | cut -f1)
            log "✓ Database $DB backup completed ($DB_SIZE)"
        else
            log "✗ ERROR: Database $DB backup failed!"
            # Continue with other databases
        fi
    done
fi

# =============================================================================
# 4. UPLOAD TO S3 (if enabled)
# =============================================================================
if [ "$S3_ENABLED" = "true" ]; then
    log "=== Uploading to S3 ==="
    
    if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
        log "✗ ERROR: S3 configuration incomplete (bucket or endpoint missing)"
    else
        # Configure AWS CLI for DigitalOcean Spaces
        aws configure set aws_access_key_id "$S3_ACCESS_KEY"
        aws configure set aws_secret_access_key "$S3_SECRET_KEY"
        aws configure set default.region "$S3_REGION"

        S3_PATH="s3://${S3_BUCKET}/postgres-backups/${TIMESTAMP}/"

        # Upload entire backup folder
        log "Uploading backup folder to S3: ${TIMESTAMP}"
        if aws s3 cp "${BACKUP_DIR}/" "${S3_PATH}" \
            --recursive \
            --endpoint-url="$S3_ENDPOINT"; then
            log "✓ Backup folder uploaded to S3: ${S3_PATH}"
        else
            log "✗ ERROR: Failed to upload backup folder to S3"
        fi
        
        # Clean up old S3 backups (delete old backup folders)
        log "Cleaning up S3 backups older than $S3_RETENTION days..."
        # Calculate cutoff date (BusyBox date compatible)
        CUTOFF_SECONDS=$(($(date +%s) - (S3_RETENTION * 86400)))
        CUTOFF_DATE_ONLY=$(date -d "@${CUTOFF_SECONDS}" +%Y%m%d 2>/dev/null || date -r ${CUTOFF_SECONDS} +%Y%m%d 2>/dev/null || date +%Y%m%d)

        # List all backup folders (prefixes) and delete old ones
        aws s3 ls "s3://${S3_BUCKET}/postgres-backups/" --endpoint-url="$S3_ENDPOINT" | grep "PRE" | awk '{print $2}' | sed 's/\///' | while read -r folder; do
            # Extract date from folder name (format: YYYYMMDD_HHMMSS)
            FOLDER_DATE=$(echo "$folder" | grep -oE '[0-9]{8}' | head -1)

            if [ -n "$FOLDER_DATE" ] && [ "$FOLDER_DATE" -lt "$CUTOFF_DATE_ONLY" ]; then
                log "Deleting old S3 backup folder: $folder (date: $FOLDER_DATE, cutoff: $CUTOFF_DATE_ONLY)"
                aws s3 rm "s3://${S3_BUCKET}/postgres-backups/${folder}/" --recursive --endpoint-url="$S3_ENDPOINT" || true
            fi
        done
        
        log "✓ S3 upload completed"
    fi
else
    log "S3 upload disabled (S3_ENABLED=false)"
fi

# =============================================================================
# 5. RSYNC TO REMOTE SERVER (if enabled)
# =============================================================================
if [ "$RSYNC_ENABLED" = "true" ]; then
    log "=== Syncing to remote server ==="
    
    if [ -z "$RSYNC_HOST" ] || [ -z "$RSYNC_USER" ] || [ -z "$RSYNC_PATH" ]; then
        log "✗ ERROR: Rsync configuration incomplete"
    else
        # Ensure SSH directory and permissions
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh 2>/dev/null || true

        # Only try to chmod if file is writable (not a read-only mount)
        if [ -f /root/.ssh/id_rsa ] && [ -w /root/.ssh/id_rsa ]; then
            chmod 600 /root/.ssh/id_rsa
        fi
        
        RSYNC_DEST="${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_PATH}/${TIMESTAMP}/"
        RSYNC_PORT=${RSYNC_PORT:-22}

        log "Syncing backup folder to: $RSYNC_DEST"

        # Create remote directory first
        ssh -p "$RSYNC_PORT" -o StrictHostKeyChecking=no "${RSYNC_USER}@${RSYNC_HOST}" \
            "mkdir -p ${RSYNC_PATH}/${TIMESTAMP}" 2>/dev/null || {
            log "✗ ERROR: Failed to create remote directory"
            return 1
        }

        # Sync entire backup folder
        if rsync -avz -e "ssh -p $RSYNC_PORT -o StrictHostKeyChecking=no" \
            "${BACKUP_DIR}/" "$RSYNC_DEST"; then
            log "✓ Backup folder synced to remote: $RSYNC_DEST"
        else
            log "✗ ERROR: Failed to sync backup folder to remote"
        fi
        
        # Clean up old remote backup folders via SSH
        log "Cleaning up remote backups older than $RSYNC_RETENTION days..."
        ssh -p "$RSYNC_PORT" -o StrictHostKeyChecking=no "${RSYNC_USER}@${RSYNC_HOST}" \
            "find ${RSYNC_PATH} -maxdepth 1 -type d -name '20*' -mtime +${RSYNC_RETENTION} -exec rm -rf {} \;" \
            2>/dev/null || log "⚠ Could not clean up remote backups (check SSH access)"
        
        log "✓ Rsync completed"
    fi
else
    log "Rsync disabled (RSYNC_ENABLED=false)"
fi



# =============================================================================
# 6. CLEAN UP OLD LOCAL BACKUPS
# =============================================================================
log "Cleaning up local backups older than $LOCAL_RETENTION days..."
find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$LOCAL_RETENTION" -exec rm -rf {} \;

# =============================================================================
# 7. SUMMARY
# =============================================================================
log "=== Backup Summary ==="
log "Backup directory: $BACKUP_DIR"
log "Backup files:"
ls -lh "$BACKUP_DIR"/postgres_*.sql.gz 2>/dev/null || log "No backups found"

BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "postgres_*.sql.gz" -type f | wc -l)
TOTAL_FOLDERS=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "20*" | wc -l)
log "Current backup: $BACKUP_COUNT files, $BACKUP_SIZE"
log "Total backup folders: $TOTAL_FOLDERS"

# =============================================================================
# 8. SEND NOTIFICATION TO ROCKET CHAT
# =============================================================================
if [ "$COMS_ENABLED" = "true" ]; then
    log "=== Sending notification to Coms ==="
    
    if [ -z "$COM_BASE_URL" ] || [ -z "$COM_USER_ID" ] || [ -z "$COM_AUTH_TOKEN" ] || [ -z "$COMS_ROOM_ID" ]; then
        log "✗ ERROR: Coms configuration incomplete (missing required variables)"
    else
        log "Sending notification to Coms: $COM_BASE_URL"
        
        # Prepare notification message with backup details
        NOTIFICATION_TEXT="PostgreSQL Backup Completed Successfully

📅 **Timestamp:** ${TIMESTAMP}
🖥️ **Host:** ${PGHOST}:${PGPORT}
📦 **Backup Size:** ${BACKUP_SIZE}
📁 **Files Created:** ${BACKUP_COUNT} backups

**Storage:**$([ "$S3_ENABLED" = "true" ] && echo " ✅ S3/Spaces" || echo " ❌ S3/Spaces")$([ "$RSYNC_ENABLED" = "true" ] && echo " ✅ Remote Sync" || echo " ❌ Remote Sync") ✅ Local

📂 **Total Backup Folders:** ${TOTAL_FOLDERS}
🧹 **Retention:** Local(${LOCAL_RETENTION}d) S3(${S3_RETENTION}d) Remote(${RSYNC_RETENTION}d)"
        
        if curl --location "${COM_BASE_URL}/api/v1/chat.postMessage" \
            --header "X-User-Id: ${COM_USER_ID}" \
            --header "X-Auth-Token: ${COM_AUTH_TOKEN}" \
            --header "Content-Type: application/json" \
            --data "{\"emoji\": \":floppy_disk:\",\"roomId\": \"${COMS_ROOM_ID}\",\"text\": \"${NOTIFICATION_TEXT}\",\"attachments\": []}" \
            --silent --show-error; then
            log "✓ COMS notification sent successfully"
        else
            log "✗ ERROR: Failed to send COMS notification"
        fi
    fi
else
    log "COMS notification disabled (COMS_ENABLED=false)"
fi

log "=== Backup Completed Successfully ==="