# OpenAlgo Update System

This directory contains scripts and configuration for upgrading OpenAlgo installations, specifically for migrating from SQLite to MySQL databases.

## Files

- **`upgrade.sh`** - Main upgrade orchestration script with integrated URL switching
- **`migration.py`** - Python script for database migration
- **`.env`** - Configuration file with broker credentials and MySQL URLs
- **`requirements.txt`** - Python dependencies for migration
- **`backups/`** - Directory for automated backups (excluded from git)
- **`.gitignore`** - Git ignore rules for backups and temporary files
- **`README.md`** - This documentation

## Usage

### Basic Upgrade
```bash
./.update/upgrade.sh
```

### Dry Run (Test Mode)
```bash
./.update/upgrade.sh --dry-run
```

### Skip Database Migration
```bash
./.update/upgrade.sh --skip-migration
```

### Switch Database URLs Only
```bash
./.update/upgrade.sh --switch-only
```

### Switch Database URLs Only (Dry Run)
```bash
./.update/upgrade.sh --switch-only --dry-run
```

### Migration Only
```bash
cd /path/to/openalgo
source .venv/bin/activate
python .update/migration.py
```

### Switch Database URLs Only
If you want to switch from SQLite to MySQL URLs without running migration:
```bash
./.update/upgrade.sh --switch-only
```

To revert back to SQLite URLs (if needed):
```bash
# Restore from backup
cp .update/backups/YYYYMMDD_HHMMSS/.env.backup .env
```

### Migration Options
```bash
# Dry run migration
python .update/migration.py --dry-run

# Skip backup creation
python .update/migration.py --no-backup

# Skip data verification
python .update/migration.py --no-verify

# Migrate specific database only
python .update/migration.py --database main
python .update/migration.py --database latency
python .update/migration.py --database logs

# Show version
python .update/migration.py --version
```

## Prerequisites

1. **Virtual Environment**: Ensure `.venv` exists in the OpenAlgo directory
2. **Dependencies**: Install migration dependencies:
   ```bash
   pip install -r .update/requirements.txt
   ```
3. **MySQL Server**: Ensure MySQL server is running and accessible
4. **Configuration**: Update `.update/.env` with correct MySQL credentials

## Process Overview

The upgrade script performs the following steps:

1. **Dependency Check** - Verifies git, environment files, and virtual environment
2. **Backup Creation** - Creates timestamped backups of databases and configuration
3. **Git Operations** - Stashes changes, pulls from upstream, merges branches
4. **Environment Setup** - Removes existing `.env`, copies from `.sample.env`, updates with broker credentials (keeps SQLite URLs)
5. **MySQL Target Setup** - Adds MySQL URLs as migration targets (MYSQL_*_URL variables)
6. **Database Migration** - Migrates SQLite databases to MySQL with verification
7. **URL Switching** - Final step: switches from SQLite URLs to MySQL URLs in `.env`
8. **Requirements Update** - Adds PyMySQL dependency to requirements.txt for MySQL support
9. **Docker Configuration** - Updates docker-compose.yaml ports to fixed values (2000:5000, 2001:8765)

## Safety Features

- **Automatic Backups** - Creates backups before any changes
- **Rollback on Error** - Automatically rolls back changes if upgrade fails
- **Data Verification** - Verifies data integrity after migration
- **Dry Run Mode** - Test upgrade process without making changes
- **Dependency Checking** - Validates prerequisites before starting

## Configuration

Update `.update/.env` with your specific configuration:

```bash
# Broker Configuration
BROKER_API_KEY=your_api_key
BROKER_API_SECRET=your_api_secret

# Network Configuration (optional)
WEBSOCKET_HOST=0.0.0.0
REDIRECT_URL=http://127.0.0.1:5000/your_broker/callback

# MySQL Configuration
MYSQL_MAIN_URL=mysql+pymysql://user:password@host:port/database
MYSQL_LATENCY_URL=mysql+pymysql://user:password@host:port/latency_db
MYSQL_LOGS_URL=mysql+pymysql://user:password@host:port/logs_db

# Add any other configuration variables you need to customize
```

**Note**: The upgrade script will copy **all variables** from `.update/.env` to the main `.env` file, 
replacing any existing values or adding new ones as needed. This includes broker credentials, 
network settings, and any other custom configuration you define.

**Important**: During the upgrade process, the script will:
1. Remove the existing `.env` file (after backup)
2. Copy `.sample.env` to create a fresh `.env` file with SQLite URLs
3. Update the new `.env` file with **all configuration values** from `.update/.env`:
   - Broker credentials (`BROKER_API_KEY`, `BROKER_API_SECRET`, etc.)
   - Network settings (`WEBSOCKET_HOST`, `REDIRECT_URL`, etc.)
   - Any other custom configuration variables
4. Add MySQL URLs as migration targets (MYSQL_*_URL variables)
5. Run migration from SQLite databases to MySQL databases
6. **Final step**: Replace SQLite URLs with MySQL URLs in `.env`

This ensures proper migration flow: SQLite (source) → MySQL (target) → Switch URLs.
All your custom configuration values from `.update/.env` will be preserved.

## Troubleshooting

### Common Issues

1. **Missing Dependencies**
   ```bash
   pip install -r .update/requirements.txt
   ```

2. **Virtual Environment Not Found**
   ```bash
   python -m venv .venv
   source .venv/bin/activate
   ```

3. **MySQL Connection Issues**
   - Verify MySQL server is running
   - Check credentials in `.update/.env`
   - Ensure MySQL user has CREATE DATABASE privileges

4. **Migration Fails**
   - Check backup files in `backups/` directory
   - Review error messages in terminal output
   - Use `--dry-run` to test before actual migration

### Recovery

If upgrade fails, backups are automatically created in `backups/YYYYMMDD_HHMMSS/`:
- `.env.backup` - Original environment file
- `*.db` - Original SQLite database files

Restore manually if needed:
```bash
cp backups/YYYYMMDD_HHMMSS/.env.backup .env
cp backups/YYYYMMDD_HHMMSS/*.db db/
```

## Security Notes

- The `.env` file contains sensitive credentials - keep it secure
- Backup files may contain sensitive data - handle appropriately
- Consider using environment variables instead of hardcoded credentials in production

## Development

To modify the upgrade process:

1. Test changes with `--dry-run` flag
2. Verify backup and rollback mechanisms work
3. Update this documentation for any new features
4. Test with different database configurations
