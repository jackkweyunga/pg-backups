#!/bin/bash
# monthly-restore-test.sh

# Create timestamped log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="restore-test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/restore-test_${TIMESTAMP}.log"

# Redirect all output to timestamped log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Restore Test Started: $(date) ==="
echo "Log file: $LOG_FILE"

BACKUP_FOLDER=$(ls -t backups/ | head -1)

echo "Testing restore of backup: $BACKUP_FOLDER"

# Create test container
POSTGRES_TAG=${POSTGRES_TAG:-17-alpine}
docker run -d --name postgres-test \
    -e POSTGRES_PASSWORD=test \
    postgres:${POSTGRES_TAG}

sleep 5

# Restore
gunzip -c backups/${BACKUP_FOLDER}/postgres_cluster.sql.gz | \
    docker exec -i postgres-test psql -U postgres

# Verify
echo "Databases:"
docker exec postgres-test psql -U postgres -c "\l"

echo -e "\nRoles:"
docker exec postgres-test psql -U postgres -c "\du"

# Cleanup
docker rm -f postgres-test

echo "✓ Restore test completed successfully"
echo "=== Restore Test Ended: $(date) ==="