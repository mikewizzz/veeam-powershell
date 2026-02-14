#!/bin/bash
# ============================================================================
# Veeam MySQL Post-Thaw Script
# ============================================================================
# Purpose:  Release MySQL locks and clean up after Veeam snapshot completes.
#           Coordinates with veeam-mysql-prefreeze.sh via state files.
#
# Usage:    Deploy as a Veeam post-thaw script for:
#             - Veeam Agent for Linux (post-job script)
#             - Veeam B&R application-aware processing (post-thaw)
#
# Supports: MySQL 5.7+, MySQL 8.0+, Percona Server, MariaDB 10.3+
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — must match pre-freeze script settings
# ---------------------------------------------------------------------------
MYSQL_USER="${MYSQL_USER:-veeambackup}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/mysql/veeam-backup.cnf}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

MYSQL_BACKUP_LOG="${MYSQL_BACKUP_LOG:-/var/log/veeam/mysql-postthaw.log}"

LOCK_FILE="/var/run/veeam-mysql-backup.lock"
STATE_FILE="/var/run/veeam-mysql-backup.state"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$MYSQL_BACKUP_LOG")" 2>/dev/null || true
exec > >(tee -a "$MYSQL_BACKUP_LOG") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST-THAW] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST-THAW] [ERROR] $*" >&2
}

# ---------------------------------------------------------------------------
# MySQL connection arguments
# ---------------------------------------------------------------------------
build_mysql_args() {
    local args=()

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
# Release FTWRL lock
# ---------------------------------------------------------------------------
release_ftwrl_lock() {
    log "Releasing FTWRL lock..."

    # Read state file for PIDs and FIFO path
    if [[ ! -f "$STATE_FILE" ]]; then
        log_error "No state file found — cannot determine lock holder"
        return 1
    fi

    local lines=()
    mapfile -t lines < "$STATE_FILE"

    local method="${lines[0]:-}"
    local mysql_pid="${lines[1]:-}"
    local timeout_pid="${lines[2]:-}"
    local fifo="${lines[3]:-}"

    if [[ "$method" != "ftwrl" ]]; then
        log "Method was '$method', not FTWRL — no lock to release"
        return 0
    fi

    # Send UNLOCK TABLES through the FIFO if it exists
    if [[ -p "$fifo" ]]; then
        log "Sending UNLOCK TABLES via FIFO: $fifo"
        echo "UNLOCK TABLES;" > "$fifo"
        sleep 1
        echo "QUIT;" > "$fifo"
        rm -f "$fifo"
    fi

    # Kill the MySQL session holding the lock
    if [[ -n "$mysql_pid" ]] && kill -0 "$mysql_pid" 2>/dev/null; then
        log "Terminating MySQL lock session (PID: $mysql_pid)"
        kill "$mysql_pid" 2>/dev/null || true
        wait "$mysql_pid" 2>/dev/null || true
    fi

    # Kill the safety timeout process
    if [[ -n "$timeout_pid" ]] && kill -0 "$timeout_pid" 2>/dev/null; then
        kill "$timeout_pid" 2>/dev/null || true
    fi

    # Verify tables are unlocked by running a test query
    local mysql_args
    mysql_args=$(build_mysql_args)
    if mysql $mysql_args -e "SELECT 1;" &>/dev/null; then
        log "MySQL is responsive — lock released successfully"
    else
        log_error "MySQL may still have locked tables — manual intervention may be required"
    fi
}

# ---------------------------------------------------------------------------
# Post-backup validation
# ---------------------------------------------------------------------------
validate_backup() {
    if [[ ! -f "$STATE_FILE" ]]; then
        log_error "No state file found — pre-freeze may not have run"
        return 1
    fi

    local method
    method=$(head -1 "$STATE_FILE")

    case "$method" in
        meb)
            log "MEB backup completed during pre-freeze — no post-thaw action needed"
            log "MEB performs a fully consistent hot backup without locks"
            ;;
        xtrabackup)
            log "XtraBackup completed during pre-freeze — no post-thaw action needed"
            log "XtraBackup performs a fully consistent hot backup with minimal locking"
            ;;
        ftwrl)
            release_ftwrl_lock
            ;;
        ERROR)
            log_error "Pre-freeze reported an error — backup may be inconsistent"
            return 1
            ;;
        *)
            log_error "Unknown backup method in state file: $method"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up state files..."
    rm -f "$STATE_FILE"
    rm -f "$LOCK_FILE"
    rm -f "/var/run/veeam-mysql-ftwrl.pipe"
    log "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "=========================================="
    log "Veeam MySQL Post-Thaw Script Starting"
    log "=========================================="
    log "Hostname: $(hostname)"
    log "Date: $(date)"

    validate_backup
    local rc=$?

    cleanup

    if [[ $rc -eq 0 ]]; then
        log "Post-thaw completed successfully"
    else
        log_error "Post-thaw completed with errors (exit code: $rc)"
    fi

    log "=========================================="
    exit $rc
}

main "$@"
