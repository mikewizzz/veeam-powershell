# Invoke-VeeamMySQLBackup

**Veeam MySQL Hot Backup Integration — NetWorker Competitive Displacement Tool**

Provides application-consistent MySQL hot backups for Veeam Backup & Replication, directly addressing the NetWorker MySQL Enterprise Backup (MEB) integration that customers cite as a migration blocker.

---

## The Competitive Problem

Dell EMC NetWorker ships a built-in MySQL Enterprise Backup module (`nsrmysqld`) that provides hot, application-consistent backups of MySQL databases. Customers migrating from NetWorker to Veeam often ask:

> *"NetWorker has MySQL Enterprise Backup integration — can Veeam do the same?"*

**The answer is yes.** This toolkit proves it.

---

## How It Works

Veeam Backup & Replication supports **application-aware processing** with custom pre-freeze and post-thaw scripts. This is the same mechanism Veeam uses for Oracle, SAP, and other application-consistent backups.

```
┌─────────────────────────────────────────────────────┐
│                  Veeam Backup Job                    │
│                                                      │
│  1. Pre-Freeze Script Executes                       │
│     ├── MEB: mysqlbackup backup-to-image (hot)       │
│     ├── XtraBackup: xtrabackup --backup (hot)        │
│     └── FTWRL: FLUSH TABLES WITH READ LOCK           │
│                                                      │
│  2. VM/Server Snapshot Created                       │
│     └── Filesystem-consistent + app-consistent       │
│                                                      │
│  3. Post-Thaw Script Executes                        │
│     ├── MEB/XtraBackup: cleanup only (no locks held) │
│     └── FTWRL: UNLOCK TABLES, release lock           │
│                                                      │
│  4. Backup Reads from Snapshot                       │
│     └── Zero impact on production MySQL              │
└─────────────────────────────────────────────────────┘
```

### Supported Backup Methods

| Method | Lock Duration | License Required | Best For |
|--------|-------------|-----------------|----------|
| **MySQL Enterprise Backup (MEB)** | None (hot) | MySQL Enterprise Edition | Customers already licensed for MEB |
| **Percona XtraBackup** | None (hot) | Free / Open Source | Most customers (recommended) |
| **FLUSH TABLES WITH READ LOCK** | Brief (snapshot only) | None | Universal fallback, any MySQL edition |

### Method Auto-Detection

The pre-freeze script automatically detects the best available method:

1. If `mysqlbackup` (MEB) is installed → uses MEB
2. If `xtrabackup` is installed → uses Percona XtraBackup
3. Otherwise → falls back to FTWRL

You can override this with `MYSQL_BACKUP_METHOD=meb|xtrabackup|ftwrl`.

---

## Components

| File | Purpose |
|------|---------|
| `Invoke-VeeamMySQLBackup.ps1` | PowerShell orchestration — assess, deploy, configure |
| `veeam-mysql-prefreeze.sh` | Linux pre-freeze script (runs before snapshot) |
| `veeam-mysql-postthaw.sh` | Linux post-thaw script (runs after snapshot) |

---

## Quick Start

### 1. Assess Target MySQL Servers

```powershell
.\Invoke-VeeamMySQLBackup.ps1 -Action Assess -TargetServers "mysql01","mysql02","mysql03"
```

This connects via SSH, checks MySQL status, detects available backup tools, and generates an HTML report showing recommended backup methods per server.

### 2. Deploy Scripts and Configure Veeam

```powershell
.\Invoke-VeeamMySQLBackup.ps1 -Action Deploy `
    -TargetServers "mysql01" `
    -VBRServer "vbr01" `
    -BackupMethod Auto
```

This will:
- Deploy pre-freeze/post-thaw scripts to `/opt/veeam/mysql/` on each server
- Create a `veeambackup` MySQL user with minimum required privileges
- Configure Veeam backup job application-aware processing (if Veeam PS module is available)

### 3. Verify

Run a test backup job and check the logs:

```bash
# On the MySQL server
cat /var/log/veeam/mysql-prefreeze.log
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Action` | Assess | `Assess`, `Deploy`, or `Report` |
| `-TargetServers` | — | Array of MySQL server hostnames |
| `-TargetServersCsv` | — | CSV file with server details |
| `-VBRServer` | localhost | Veeam B&R server hostname |
| `-MySQLUser` | veeambackup | MySQL backup user to create |
| `-MySQLPassword` | (generated) | SecureString password |
| `-MySQLPort` | 3306 | MySQL port |
| `-BackupMethod` | Auto | `Auto`, `MEB`, `XtraBackup`, `FTWRL` |
| `-ScriptDeployPath` | /opt/veeam/mysql | Script location on targets |
| `-BackupDirectory` | /var/veeam/mysql_backup | Backup staging directory |
| `-SSHKeyPath` | — | SSH private key path |
| `-SSHUser` | root | SSH username |
| `-OutputDirectory` | .\VeeamMySQLBackup_Output | Report output location |
| `-SkipVeeamConfig` | false | Skip Veeam job configuration |

---

## Manual Deployment (Without PowerShell Script)

If you prefer to deploy manually:

### Step 1: Copy Scripts to the MySQL Server

```bash
scp veeam-mysql-prefreeze.sh root@mysqlserver:/opt/veeam/mysql/prefreeze.sh
scp veeam-mysql-postthaw.sh root@mysqlserver:/opt/veeam/mysql/postthaw.sh
chmod 750 /opt/veeam/mysql/*.sh
```

### Step 2: Create MySQL Backup User

```sql
-- For XtraBackup (recommended)
CREATE USER 'veeambackup'@'localhost' IDENTIFIED BY 'YourSecurePassword';
GRANT RELOAD, REPLICATION CLIENT, PROCESS, LOCK TABLES ON *.* TO 'veeambackup'@'localhost';

-- For MySQL 8.0+ add BACKUP_ADMIN
GRANT BACKUP_ADMIN ON *.* TO 'veeambackup'@'localhost';

FLUSH PRIVILEGES;
```

### Step 3: Create Credentials File

```bash
cat > /etc/mysql/veeam-backup.cnf << 'EOF'
[client]
user=veeambackup
password=YourSecurePassword
EOF
chmod 600 /etc/mysql/veeam-backup.cnf
```

### Step 4: Configure in Veeam B&R Console

1. Edit the backup job → **Guest Processing**
2. Enable **Application-Aware Processing**
3. Click **Applications** → select the VM → **Edit**
4. Go to **Scripts** tab
5. Set:
   - Pre-freeze script: `/opt/veeam/mysql/prefreeze.sh`
   - Post-thaw script: `/opt/veeam/mysql/postthaw.sh`

### Step 5: For Veeam Agent for Linux

```bash
# In the Veeam Agent backup job configuration:
veeamconfig job create --name "MySQL-Backup" \
    --reponame "your-repo" \
    --includedirs "/var/lib/mysql" \
    --prefreezecommand "/opt/veeam/mysql/prefreeze.sh" \
    --postthawcommand "/opt/veeam/mysql/postthaw.sh"
```

---

## SE Talking Points: NetWorker vs. Veeam MySQL Backup

Use these when positioning against NetWorker's MEB integration:

### 1. Same Tool, Better Integration

> "NetWorker's MySQL module is a wrapper around MySQL Enterprise Backup — the same tool our pre-freeze scripts can use. The difference is that Veeam's approach is transparent and customizable, while NetWorker's is a black box."

### 2. More Options, Not Fewer

> "NetWorker only supports MEB, which requires a MySQL Enterprise Edition license. Veeam supports MEB *and* Percona XtraBackup (free, open-source, feature-equivalent for InnoDB) *and* a universal FTWRL fallback. Your customers get choice."

### 3. No Additional Module License

> "NetWorker charges for the MySQL backup module separately. With Veeam, MySQL application-aware processing is included — no additional license."

### 4. Veeam Agent for Linux

> "For physical MySQL servers or containers, Veeam Agent for Linux provides the same pre/post script integration. NetWorker requires the full NetWorker client installation."

### 5. Recovery Capabilities

> "With Veeam, you get Instant VM Recovery, SureBackup verification, and Veeam Explorer capabilities on top of the MySQL-consistent backup. NetWorker's recovery is limited to file-level restore."

### Common Objection Handling

| Objection | Response |
|-----------|----------|
| "NetWorker has native MEB integration" | "So does Veeam — our pre-freeze scripts invoke the same `mysqlbackup` binary. The difference is we also support free alternatives." |
| "We need zero-downtime hot backups" | "Both MEB and XtraBackup provide true hot backups with zero application downtime. FTWRL is only used as a fallback." |
| "Scripts feel less enterprise-grade" | "Veeam's application-aware processing for Oracle RMAN uses the same script-based approach and protects hundreds of thousands of Oracle databases worldwide. This is a proven architecture." |
| "We've been using NetWorker for years" | "This toolkit assesses your MySQL servers and generates a migration plan. Let's run the assessment and show you exactly what the Veeam deployment looks like." |

---

## Environment Variables

The pre-freeze and post-thaw scripts can be configured via environment variables or by editing the defaults at the top of each script:

| Variable | Default | Description |
|----------|---------|-------------|
| `MYSQL_BACKUP_METHOD` | auto | Force backup method: `auto`, `meb`, `xtrabackup`, `ftwrl` |
| `MYSQL_USER` | veeambackup | MySQL username |
| `MYSQL_PASSWORD` | (empty) | MySQL password (prefer defaults-file) |
| `MYSQL_DEFAULTS_FILE` | /etc/mysql/veeam-backup.cnf | MySQL option file with credentials |
| `MYSQL_SOCKET` | (empty) | MySQL socket path (overrides host/port) |
| `MYSQL_HOST` | localhost | MySQL hostname |
| `MYSQL_PORT` | 3306 | MySQL port |
| `MYSQL_BACKUP_DIR` | /var/veeam/mysql_backup | Staging directory for MEB/XtraBackup |
| `MEB_BINARY` | mysqlbackup | Path to MEB binary |
| `MEB_EXTRA_ARGS` | --compress --compress-level=4 | Additional MEB arguments |
| `XTRABACKUP_BINARY` | xtrabackup | Path to XtraBackup binary |
| `XTRABACKUP_EXTRA_ARGS` | --compress --compress-threads=4 | Additional XtraBackup arguments |
| `FTWRL_TIMEOUT` | 300 | Safety timeout (seconds) to auto-release FTWRL lock |

---

## Troubleshooting

### Pre-freeze script fails

```bash
# Check the log
cat /var/log/veeam/mysql-prefreeze.log

# Common issues:
# 1. MySQL credentials incorrect → verify /etc/mysql/veeam-backup.cnf
# 2. Insufficient privileges → re-run GRANT statements
# 3. Disk space for MEB/XtraBackup → check MYSQL_BACKUP_DIR
# 4. XtraBackup version mismatch → ensure version matches MySQL version
```

### Lock not released (FTWRL method)

```bash
# Check if lock process is still running
cat /var/run/veeam-mysql-backup.state

# Manual unlock if needed
mysql -u root -e "UNLOCK TABLES;"
rm -f /var/run/veeam-mysql-backup.*
```

### Veeam job shows "Script failed"

1. Verify script permissions: `ls -la /opt/veeam/mysql/`
2. Verify script is executable: `chmod 750 /opt/veeam/mysql/*.sh`
3. Check for Windows line endings: `file /opt/veeam/mysql/prefreeze.sh` (should show "ASCII text")
4. Fix line endings if needed: `dos2unix /opt/veeam/mysql/*.sh`

---

## Requirements

- **Target Servers**: Linux with MySQL 5.7+ / MySQL 8.0+ / Percona Server / MariaDB 10.3+
- **Backup Tools** (optional): MySQL Enterprise Backup or Percona XtraBackup
- **Veeam**: Backup & Replication v12+ or Veeam Agent for Linux v6+
- **Access**: SSH root access to target servers (for deployment)
- **PowerShell**: 5.1+ (for orchestration script)

---

## License

MIT License — see the repository root LICENSE file.
