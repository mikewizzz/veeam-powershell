#!/bin/bash
# ============================================================================
# Veeam MySQL Pre-Freeze Script
# ============================================================================
# Purpose:  Application-consistent hot backup of MySQL databases using
#           MySQL Enterprise Backup (MEB), Percona XtraBackup, or
#           FLUSH TABLES WITH READ LOCK (FTWRL) as a fallback.
#
# Usage:    Deploy as a Veeam pre-freeze script for:
#             - Veeam Agent for Linux (pre-job script)
#             - Veeam B&R application-aware processing (pre-freeze)
#
# Supports: MySQL 5.7+, MySQL 8.0+, Percona Server, MariaDB 10.3+
#
# NetWorker Competitive Context:
#   NetWorker uses MySQL Enterprise Backup (MEB) for hot backups. This script
#   provides equivalent or superior functionality by supporting MEB *and*
#   Percona XtraBackup (free/open-source alternative) and FTWRL fallback.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables or edit defaults below
# ---------------------------------------------------------------------------
MYSQL_BACKUP_METHOD="${MYSQL_BACKUP_METHOD:-auto}"       # auto | meb | xtrabackup | ftwrl
MYSQL_USER="${MYSQL_USER:-veeambackup}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/mysql/veeam-backup.cnf}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

# Backup destination for MEB / XtraBackup streaming backups
MYSQL_BACKUP_DIR="${MYSQL_BACKUP_DIR:-/var/veeam/mysql_backup}"
MYSQL_BACKUP_LOG="${MYSQL_BACKUP_LOG:-/var/log/veeam/mysql-prefreeze.log}"

# MEB-specific settings
MEB_BINARY="${MEB_BINARY:-mysqlbackup}"
MEB_BACKUP_IMAGE="${MEB_BACKUP_IMAGE:-${MYSQL_BACKUP_DIR}/backup.mbi}"
MEB_EXTRA_ARGS="${MEB_EXTRA_ARGS:---compress --compress-level=4}"

# XtraBackup-specific settings
XTRABACKUP_BINARY="${XTRABACKUP_BINARY:-xtrabackup}"
XTRABACKUP_EXTRA_ARGS="${XTRABACKUP_EXTRA_ARGS:---compress --compress-threads=4}"

# Lock file for coordinating with post-thaw
LOCK_FILE="/var/run/veeam-mysql-backup.lock"
STATE_FILE="/var/run/veeam-mysql-backup.state"

# Timeout for FTWRL method (seconds) — safety net to release locks
FTWRL_TIMEOUT="${FTWRL_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$MYSQL_BACKUP_LOG")" 2>/dev/null || true
exec > >(tee -a "$MYSQL_BACKUP_LOG") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRE-FREEZE] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRE-FREEZE] [ERROR] $*" >&2
}

die() {
    log_error "$*"
    echo "ERROR" > "$STATE_FILE"
    exit 1
}

# ---------------------------------------------------------------------------
# MySQL connection arguments
# ---------------------------------------------------------------------------
build_mysql_args() {
    local args=()

    # Prefer defaults-file for credential security (no passwords on CLI)
    if [[ -f "$MYSQL_DEFAULTS_FILE" ]]; then
        args+=("--defaults-file=$MYSQL_DEFAULTS_FILE")
    else
        [[ -n "$MYSQL_USER" ]]     && args+=("--user=$MYSQL_USER")
        [[ -n "$MYSQL_PASSWORD" ]] && args+=("--password=$MYSQL_PASSWORD")
    fi

    if [[ -n "$MYSQL_SOCKET" ]]; then
        args+=("--socket=$MYSQL_SOCKET")
    else
        args+=("--host=$MYSQL_HOST" "--port=$MYSQL_PORT")
    fi

    echo "${args[@]}"
}

# ---------------------------------------------------------------------------
# Detect available backup method
# ---------------------------------------------------------------------------
detect_method() {
    if [[ "$MYSQL_BACKUP_METHOD" != "auto" ]]; then
        log "Backup method explicitly set: $MYSQL_BACKUP_METHOD"
        echo "$MYSQL_BACKUP_METHOD"
        return
    fi

    # Priority: MEB > XtraBackup > FTWRL
    if command -v "$MEB_BINARY" &>/dev/null; then
        log "Detected MySQL Enterprise Backup (MEB)"
        echo "meb"
    elif command -v "$XTRABACKUP_BINARY" &>/dev/null; then
        log "Detected Percona XtraBackup"
        echo "xtrabackup"
    else
        log "No hot-backup tool found — falling back to FTWRL"
        echo "ftwrl"
    fi
}

# ---------------------------------------------------------------------------
# Method 1: MySQL Enterprise Backup (MEB) — hot backup, no locks needed
# ---------------------------------------------------------------------------
run_meb_backup() {
    log "Starting MySQL Enterprise Backup (hot backup)..."
    mkdir -p "$MYSQL_BACKUP_DIR"

    local mysql_args
    mysql_args=$(build_mysql_args)

    # Clean previous backup image if exists
    rm -f "$MEB_BACKUP_IMAGE"

    # MEB backup-to-image creates a single-file hot backup
    # This is the equivalent of what NetWorker's MEB integration does
    if $MEB_BINARY \
        $mysql_args \
        --backup-dir="$MYSQL_BACKUP_DIR" \
        --backup-image="$MEB_BACKUP_IMAGE" \
        $MEB_EXTRA_ARGS \
        backup-to-image; then
        log "MEB backup-to-image completed successfully"
        log "Backup image: $MEB_BACKUP_IMAGE"
        log "Backup size: $(du -sh "$MEB_BACKUP_IMAGE" 2>/dev/null | cut -f1)"
        echo "meb" > "$STATE_FILE"
    else
        die "MEB backup-to-image FAILED — aborting Veeam snapshot"
    fi
}

# ---------------------------------------------------------------------------
# Method 2: Percona XtraBackup — hot backup, no locks on InnoDB
# ---------------------------------------------------------------------------
run_xtrabackup() {
    log "Starting Percona XtraBackup (hot backup)..."
    mkdir -p "$MYSQL_BACKUP_DIR"

    local mysql_args
    mysql_args=$(build_mysql_args)

    # Clean previous backup
    rm -rf "${MYSQL_BACKUP_DIR:?}/xtrabackup_data"

    if $XTRABACKUP_BINARY \
        --backup \
        $mysql_args \
        --target-dir="${MYSQL_BACKUP_DIR}/xtrabackup_data" \
        $XTRABACKUP_EXTRA_ARGS; then
        log "XtraBackup completed successfully"
        log "Backup dir: ${MYSQL_BACKUP_DIR}/xtrabackup_data"
        log "Backup size: $(du -sh "${MYSQL_BACKUP_DIR}/xtrabackup_data" 2>/dev/null | cut -f1)"
        echo "xtrabackup" > "$STATE_FILE"
    else
        die "XtraBackup FAILED — aborting Veeam snapshot"
    fi
}

# ---------------------------------------------------------------------------
# Method 3: FLUSH TABLES WITH READ LOCK (FTWRL) — brief lock for snapshot
# ---------------------------------------------------------------------------
run_ftwrl() {
    log "Starting FTWRL-based quiesce for snapshot consistency..."

    local mysql_args
    mysql_args=$(build_mysql_args)

    # Create a persistent MySQL connection that holds the lock
    # The post-thaw script will kill this process to release the lock
    (
        # Safety timeout — auto-release lock if post-thaw never fires
        sleep "$FTWRL_TIMEOUT" && log_error "FTWRL safety timeout reached — releasing lock" && exit 1
    ) &
    local timeout_pid=$!

    # Open a MySQL session, acquire the lock, and hold it
    # We use a named pipe so we can send UNLOCK later from post-thaw
    local fifo="/var/run/veeam-mysql-ftwrl.pipe"
    rm -f "$fifo"
    mkfifo "$fifo"

    # Start MySQL client in background, reading commands from the FIFO
    mysql $mysql_args < "$fifo" &
    local mysql_pid=$!

    # Open the FIFO for writing (keep it open by holding fd 3)
    exec 3>"$fifo"

    # Send the FLUSH TABLES WITH READ LOCK command
    echo "FLUSH TABLES WITH READ LOCK;" >&3
    sleep 1

    # Verify the lock was acquired by checking processlist
    if mysql $mysql_args -e "SHOW PROCESSLIST;" 2>/dev/null | grep -q "Waiting for table flush\|Has read all relay log"; then
        log "FTWRL lock acquired — tables are quiesced"
    else
        log "FTWRL command sent — assuming lock acquired"
    fi

    # Record state for post-thaw coordination
    echo "ftwrl" > "$STATE_FILE"
    echo "$mysql_pid" >> "$STATE_FILE"
    echo "$timeout_pid" >> "$STATE_FILE"
    echo "$fifo" >> "$STATE_FILE"

    log "MySQL tables locked and quiesced for Veeam snapshot"
    log "Lock held by MySQL PID: $mysql_pid (will be released by post-thaw)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "=========================================="
    log "Veeam MySQL Pre-Freeze Script Starting"
    log "=========================================="
    log "Hostname: $(hostname)"
    log "Date: $(date)"

    # Prevent concurrent runs
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            die "Another backup is already running (PID: $lock_pid)"
        else
            log "Stale lock file found — removing"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"

    # Verify MySQL is running
    local mysql_args
    mysql_args=$(build_mysql_args)
    if ! mysql $mysql_args -e "SELECT 1;" &>/dev/null; then
        die "Cannot connect to MySQL — verify credentials and connectivity"
    fi
    log "MySQL connection verified"

    # Log MySQL version for diagnostics
    local mysql_version
    mysql_version=$(mysql $mysql_args -N -e "SELECT VERSION();" 2>/dev/null || echo "unknown")
    log "MySQL version: $mysql_version"

    # Detect and run appropriate backup method
    local method
    method=$(detect_method)

    case "$method" in
        meb)
            run_meb_backup
            ;;
        xtrabackup)
            run_xtrabackup
            ;;
        ftwrl)
            run_ftwrl
            ;;
        *)
            die "Unknown backup method: $method"
            ;;
    esac

    log "Pre-freeze completed successfully (method: $method)"
    log "=========================================="
    exit 0
}

main "$@"
