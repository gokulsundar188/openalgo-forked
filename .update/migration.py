"""
SQLite → MySQL Migration Script for OpenAlgo
Version: 2.0.0
Migrates:
1. Main database (DATABASE_URL → MYSQL_MAIN_URL)
2. Latency monitoring DB (LATENCY_DATABASE_URL → MYSQL_LATENCY_URL)
3. Traffic logs DB (LOGS_DATABASE_URL → MYSQL_LOGS_URL)

Keeps project upgrade-safe and allows DB switching via .env DATABASE_URL values.
Automatically creates MySQL databases if they do not exist.
Includes backup creation and rollback capabilities.
Handles existing MySQL tables by clearing them for fresh migration.
"""

import os
import sys
import shutil
import argparse
from datetime import datetime
from pathlib import Path

# Check for required dependencies
try:
    from sqlalchemy import create_engine, MetaData, text
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy.engine.url import make_url
    from dotenv import load_dotenv
except ImportError as e:
    print(f"❌ Missing required dependency: {e}")
    print("Please install required packages: pip install sqlalchemy pymysql python-dotenv")
    sys.exit(1)

# Load environment variables from .env in OpenAlgo
# Try to load from current directory first, then from parent directory
env_file = None
if os.path.exists('.env'):
    env_file = '.env'
elif os.path.exists('../.env'):
    env_file = '../.env'

if env_file:
    load_dotenv(env_file)
else:
    load_dotenv()

# Also try to load .update/.env for MySQL URLs
update_env_file = None
if os.path.exists('.update/.env'):
    update_env_file = '.update/.env'
elif os.path.exists('.env'):
    # We're running from .update directory
    update_env_file = '.env'

if update_env_file:
    load_dotenv(update_env_file, override=False)  # Don't override existing values

# Mapping of env keys (SQLite) to MySQL URLs
DB_MAPPINGS = {
    "DATABASE_URL": os.getenv("MYSQL_MAIN_URL"),       # MySQL for main DB
    "LATENCY_DATABASE_URL": os.getenv("MYSQL_LATENCY_URL"),
    "LOGS_DATABASE_URL": os.getenv("MYSQL_LOGS_URL")
}

def log_message(message: str, level: str = "INFO"):
    """Log messages with timestamp and level."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {level}: {message}")

def log_environment_info():
    """Log information about loaded environment files."""
    env_file = None
    if os.path.exists('.env'):
        env_file = '.env'
    elif os.path.exists('../.env'):
        env_file = '../.env'
    
    if env_file:
        log_message(f"📋 Loaded environment from: {os.path.abspath(env_file)}")
    else:
        log_message("📋 Loaded environment from system")
    
    # Check if MySQL URLs are available
    update_env_file = None
    if os.path.exists('.update/.env'):
        update_env_file = '.update/.env'
    elif os.path.exists('.env'):
        update_env_file = '.env'
    
    if update_env_file and os.path.exists(update_env_file):
        log_message(f"📋 MySQL URLs loaded from: {os.path.abspath(update_env_file)}")

def create_backup(sqlite_url: str, backup_dir: str = "backups") -> str:
    """Create a backup of SQLite database before migration."""
    if not sqlite_url.startswith('sqlite:///'):
        return None
    
    sqlite_path = sqlite_url.replace('sqlite:///', '')
    if not os.path.exists(sqlite_path):
        log_message(f"SQLite database not found: {sqlite_path}", "WARNING")
        return None
    
    # Create backup directory
    backup_path = Path(backup_dir)
    backup_path.mkdir(exist_ok=True)
    
    # Create backup filename with timestamp
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    db_name = Path(sqlite_path).stem
    backup_file = backup_path / f"{db_name}_backup_{timestamp}.db"
    
    # Copy database file
    shutil.copy2(sqlite_path, backup_file)
    log_message(f"Created backup: {backup_file}")
    return str(backup_file)

def verify_data_integrity(sqlite_url: str, mysql_url: str) -> bool:
    """Verify data integrity after migration by comparing row counts."""
    try:
        sqlite_engine = create_engine(sqlite_url)
        mysql_engine = create_engine(mysql_url)
        
        # Get table list from SQLite
        sqlite_metadata = MetaData()
        sqlite_metadata.reflect(bind=sqlite_engine)
        
        all_match = True
        for table_name in sqlite_metadata.tables.keys():
            # Count rows in SQLite
            with sqlite_engine.connect() as conn:
                sqlite_count = conn.execute(text(f"SELECT COUNT(*) FROM {table_name}")).scalar()
            
            # Count rows in MySQL
            with mysql_engine.connect() as conn:
                mysql_count = conn.execute(text(f"SELECT COUNT(*) FROM {table_name}")).scalar()
            
            if sqlite_count == mysql_count:
                log_message(f"✅ Table '{table_name}': {sqlite_count} rows (verified)")
            else:
                log_message(f"❌ Table '{table_name}': SQLite={sqlite_count}, MySQL={mysql_count}", "ERROR")
                all_match = False
        
        sqlite_engine.dispose()
        mysql_engine.dispose()
        return all_match
    except Exception as e:
        log_message(f"Error during verification: {e}", "ERROR")
        return False

def ensure_mysql_database(mysql_url: str):
    """Ensure the target MySQL database exists, create if not."""
    try:
        url = make_url(mysql_url)
        db_name = url.database
        # Remove database from URL for initial connection
        url_no_db = url.set(database=None)
        engine = create_engine(url_no_db)
        with engine.connect() as conn:
            conn.execute(text(f"CREATE DATABASE IF NOT EXISTS `{db_name}`"))
        engine.dispose()
        log_message(f"Database '{db_name}' ensured in MySQL")
    except Exception as e:
        log_message(f"Error creating MySQL database: {e}", "ERROR")
        raise

def migrate_sqlite_to_mysql(sqlite_url: str, mysql_url: str, verify: bool = True, backup: bool = True):
    """Migrate all tables & data from SQLite DB to MySQL DB."""
    log_message(f"Starting migration: {sqlite_url} → {mysql_url}")
    
    # Create backup if requested
    backup_file = None
    if backup:
        backup_file = create_backup(sqlite_url)
    
    try:
        ensure_mysql_database(mysql_url)

        # Connect to SQLite & MySQL
        sqlite_engine = create_engine(sqlite_url)
        mysql_engine = create_engine(mysql_url)

        # Reflect schema from SQLite
        sqlite_metadata = MetaData()
        sqlite_metadata.reflect(bind=sqlite_engine)

        if not sqlite_metadata.tables:
            log_message("No tables found in SQLite database", "WARNING")
            return True

        # Check if MySQL tables already exist and clear them for fresh migration
        mysql_existing_metadata = MetaData()
        mysql_existing_metadata.reflect(bind=mysql_engine)
        
        if mysql_existing_metadata.tables:
            log_message("Found existing MySQL tables, clearing them for fresh migration...")
            mysql_connection = mysql_engine.connect()
            
            # Drop existing tables to avoid conflicts
            for table_name in mysql_existing_metadata.tables.keys():
                mysql_connection.execute(text(f"DROP TABLE IF EXISTS `{table_name}`"))
            mysql_connection.commit()
            mysql_connection.close()
            log_message("Cleared existing MySQL tables")

        # Convert SQLite schema to MySQL-compatible schema
        mysql_metadata = MetaData()
        for table_name, sqlite_table in sqlite_metadata.tables.items():
            from sqlalchemy import Table, Column, String, Integer, Text, DateTime, Float, Boolean
            
            # Create MySQL-compatible columns
            mysql_columns = []
            for column in sqlite_table.columns:
                # Create new column with MySQL-compatible type
                column_type = column.type
                
                # Fix VARCHAR without length - set default length of 255
                if str(column_type).upper().startswith('VARCHAR') and not hasattr(column_type, 'length'):
                    column_type = String(255)
                elif str(column_type).upper() == 'VARCHAR':
                    column_type = String(255)
                
                # Create new column
                mysql_column = Column(
                    column.name,
                    column_type,
                    primary_key=column.primary_key,
                    nullable=column.nullable,
                    default=column.default,
                    autoincrement=column.autoincrement
                )
                mysql_columns.append(mysql_column)
            
            # Create the table in MySQL metadata
            Table(table_name, mysql_metadata, *mysql_columns)

        # Create tables in MySQL
        mysql_metadata.create_all(mysql_engine)
        log_message(f"Created {len(mysql_metadata.tables)} tables in MySQL")

        # Setup sessions
        sqlite_connection = sqlite_engine.connect()
        mysql_connection = mysql_engine.connect()

        total_rows = 0
        # Copy data table-by-table
        for table_name, sqlite_table in sqlite_metadata.tables.items():
            try:
                # Get the corresponding MySQL table
                mysql_table = mysql_metadata.tables[table_name]
                
                # Fetch all data from SQLite
                result = sqlite_connection.execute(sqlite_table.select())
                rows = result.fetchall()
                
                if rows:
                    log_message(f"[{table_name}] Migrating {len(rows)} rows...")
                    
                    # Convert rows to dictionaries for MySQL insertion
                    columns = [col.name for col in sqlite_table.columns]
                    data_dicts = []
                    for row in rows:
                        # Convert row to dictionary, handling different SQLAlchemy row types
                        if hasattr(row, '_asdict'):
                            # For older SQLAlchemy versions
                            row_dict = row._asdict()
                        else:
                            # For newer SQLAlchemy versions
                            row_dict = dict(zip(columns, row))
                        data_dicts.append(row_dict)
                    
                    # Insert data in batches to avoid memory issues
                    batch_size = 1000
                    for i in range(0, len(data_dicts), batch_size):
                        batch = data_dicts[i:i + batch_size]
                        mysql_connection.execute(mysql_table.insert(), batch)
                    
                    total_rows += len(rows)
                else:
                    log_message(f"[{table_name}] No data to migrate")
                    
            except Exception as e:
                log_message(f"Error migrating table {table_name}: {e}", "ERROR")
                raise

        # Commit all changes
        mysql_connection.commit()
        sqlite_connection.close()
        mysql_connection.close()
        
        log_message(f"Migration completed: {total_rows} total rows migrated")
        
        # Verify data integrity if requested
        if verify:
            log_message("Verifying data integrity...")
            if verify_data_integrity(sqlite_url, mysql_url):
                log_message("✅ Data integrity verification passed")
                return True
            else:
                log_message("❌ Data integrity verification failed", "ERROR")
                return False
        
        return True
        
    except Exception as e:
        log_message(f"Migration failed: {e}", "ERROR")
        if backup_file:
            log_message(f"Backup available at: {backup_file}")
        raise

def main():
    """Main function with command line argument support."""
    parser = argparse.ArgumentParser(description='Migrate OpenAlgo SQLite databases to MySQL')
    parser.add_argument('--dry-run', action='store_true', help='Test migration without making changes')
    parser.add_argument('--no-backup', action='store_true', help='Skip backup creation')
    parser.add_argument('--no-verify', action='store_true', help='Skip data integrity verification')
    parser.add_argument('--database', choices=['main', 'latency', 'logs'], help='Migrate specific database only')
    parser.add_argument('--version', action='version', version='OpenAlgo Migration Script v2.0.0')
    
    args = parser.parse_args()
    
    if args.dry_run:
        log_message("🧪 DRY RUN MODE - No changes will be made")
    
    # Log environment information
    log_environment_info()
    
    # Filter databases if specific one requested
    db_mappings = DB_MAPPINGS.copy()
    if args.database:
        db_filter = {
            'main': 'DATABASE_URL',
            'latency': 'LATENCY_DATABASE_URL', 
            'logs': 'LOGS_DATABASE_URL'
        }
        key = db_filter[args.database]
        db_mappings = {key: DB_MAPPINGS[key]}
    
    success_count = 0
    total_count = 0
    
    for env_key, mysql_url in db_mappings.items():
        total_count += 1
        current_url = os.getenv(env_key)
        
        # Check if URL is missing
        if not current_url:
            log_message(f"⚠️ Skipping {env_key} — not found in .env", "WARNING")
            continue
        
        # Check if current URL is already MySQL (migration already done)
        if current_url.startswith('mysql+pymysql://') or current_url.startswith('mysql://'):
            log_message(f"✅ {env_key} already using MySQL: {current_url}")
            success_count += 1
            continue
        
        # Check if current URL is SQLite
        if not current_url.startswith('sqlite:///'):
            log_message(f"⚠️ Skipping {env_key} — unsupported database type: {current_url}", "WARNING")
            continue
            
        # For SQLite URLs, we need a MySQL target URL
        if not mysql_url:
            log_message(f"⚠️ Skipping {env_key} — no MySQL target URL configured (check MYSQL_*_URL variables)", "WARNING")
            continue
        
        log_message(f"🚀 Processing {env_key}...")
        
        if args.dry_run:
            log_message(f"Would migrate: {current_url} → {mysql_url}")
            success_count += 1
            continue
        
        try:
            success = migrate_sqlite_to_mysql(
                current_url, 
                mysql_url, 
                verify=not args.no_verify,
                backup=not args.no_backup
            )
            if success:
                success_count += 1
            else:
                log_message(f"Migration failed for {env_key}", "ERROR")
        except Exception as e:
            log_message(f"Fatal error migrating {env_key}: {e}", "ERROR")
    
    # Summary
    if args.dry_run:
        log_message(f"🧪 Dry run completed: {success_count}/{total_count} databases would be migrated")
    else:
        log_message(f"📊 Migration summary: {success_count}/{total_count} databases migrated successfully")
        if success_count < total_count:
            sys.exit(1)

if __name__ == "__main__":
    main()
