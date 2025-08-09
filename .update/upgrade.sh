#!/bin/bash
set -e  # Exit on error

########################################
# CONFIG
########################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # directory where script lives

# Auto-detect OpenAlgo directory (look for app.py as indicator)
if [[ -f "$SCRIPT_DIR/../app.py" ]]; then
    OPENALGO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    # Fallback to environment variable or default
    OPENALGO_DIR="${OPENALGO_DIR:-$HOME/storage/works/innovsoft/MarketCalls/openalgo-forked}"
fi

MY_ENV_FILE="$SCRIPT_DIR/.env"
SAMPLE_ENV_FILE="$OPENALGO_DIR/.sample.env"
ENV_FILE="$OPENALGO_DIR/.env"
MIGRATION_SCRIPT="$SCRIPT_DIR/migration.py"
VENV_PATH="$OPENALGO_DIR/.venv"

# Command line arguments
DRY_RUN=false
SKIP_MIGRATION=false
SWITCH_ONLY=false
BACKUP_DIR="$OPENALGO_DIR/.update/backups/$(date +%Y%m%d_%H%M%S)"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-migration)
            SKIP_MIGRATION=true
            shift
            ;;
        --switch-only)
            SWITCH_ONLY=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --dry-run         Test upgrade without making changes"
            echo "  --skip-migration  Skip database migration step"
            echo "  --switch-only     Only switch database URLs (no git operations or migration)"
            echo "  --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

########################################
# UTILITY FUNCTIONS
########################################
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_dependencies() {
    log_message "🔍 Checking dependencies..."
    
    # Check if git is available
    if ! command -v git &> /dev/null; then
        log_message "❌ Git is not installed"
        exit 1
    fi
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_message "❌ Not in a git repository"
        exit 1
    fi
    
    # Check if sample env file exists
    if [[ ! -f "$SAMPLE_ENV_FILE" ]]; then
        log_message "❌ Sample environment file not found: $SAMPLE_ENV_FILE"
        exit 1
    fi
    
    # Check if local env file exists
    if [[ ! -f "$MY_ENV_FILE" ]]; then
        log_message "❌ Local environment file not found: $MY_ENV_FILE"
        exit 1
    fi
    
    log_message "✅ Dependencies check passed"
}

create_backup() {
    if [[ "$DRY_RUN" == true ]]; then
        log_message "Would create backup in: $BACKUP_DIR"
        return
    fi
    
    log_message "📦 Creating backup..."
    mkdir -p "$BACKUP_DIR"
    
    # Backup current .env if it exists
    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$BACKUP_DIR/.env.backup"
    fi
    
    # Backup databases if they exist (only if not switch-only mode)
    if [[ "$SWITCH_ONLY" == false ]]; then
        for db_file in "$OPENALGO_DIR/db"/*.db; do
            if [[ -f "$db_file" ]]; then
                cp "$db_file" "$BACKUP_DIR/"
            fi
        done
    fi
    
    log_message "✅ Backup created in: $BACKUP_DIR"
}

switch_database_urls() {
    log_message "🔄 Switching OpenAlgo .env from SQLite to MySQL URLs..."
    
    # Get MySQL URLs from local env file (handle spaces and quotes)
    MYSQL_MAIN_URL=$(grep "MYSQL_MAIN_URL" "$MY_ENV_FILE" | cut -d'=' -f2 | tr -d "' ")
    MYSQL_LATENCY_URL=$(grep "MYSQL_LATENCY_URL" "$MY_ENV_FILE" | cut -d'=' -f2 | tr -d "' ")
    MYSQL_LOGS_URL=$(grep "MYSQL_LOGS_URL" "$MY_ENV_FILE" | cut -d'=' -f2 | tr -d "' ")
    
    # Validate URLs were found
    if [[ -z "$MYSQL_MAIN_URL" || -z "$MYSQL_LATENCY_URL" || -z "$MYSQL_LOGS_URL" ]]; then
        log_message "❌ Could not find MySQL URLs in $MY_ENV_FILE"
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "Would switch to MySQL URLs:"
        log_message "  DATABASE_URL: $MYSQL_MAIN_URL"
        log_message "  LATENCY_DATABASE_URL: $MYSQL_LATENCY_URL"
        log_message "  LOGS_DATABASE_URL: $MYSQL_LOGS_URL"
        return 0
    fi
    
    log_message "📋 Switching to MySQL URLs:"
    log_message "  MYSQL_MAIN_URL: $MYSQL_MAIN_URL"
    log_message "  MYSQL_LATENCY_URL: $MYSQL_LATENCY_URL"
    log_message "  MYSQL_LOGS_URL: $MYSQL_LOGS_URL"
    
    # Replace SQLite URLs with MySQL URLs - handle spaces around equals
    sed -i '' "s|^DATABASE_URL[ ]*=.*|DATABASE_URL = $MYSQL_MAIN_URL|" "$ENV_FILE" 2>/dev/null || sed -i "s|^DATABASE_URL[ ]*=.*|DATABASE_URL = $MYSQL_MAIN_URL|" "$ENV_FILE"
    sed -i '' "s|^LATENCY_DATABASE_URL[ ]*=.*|LATENCY_DATABASE_URL = $MYSQL_LATENCY_URL|" "$ENV_FILE" 2>/dev/null || sed -i "s|^LATENCY_DATABASE_URL[ ]*=.*|LATENCY_DATABASE_URL = $MYSQL_LATENCY_URL|" "$ENV_FILE"
    sed -i '' "s|^LOGS_DATABASE_URL[ ]*=.*|LOGS_DATABASE_URL = $MYSQL_LOGS_URL|" "$ENV_FILE" 2>/dev/null || sed -i "s|^LOGS_DATABASE_URL[ ]*=.*|LOGS_DATABASE_URL = $MYSQL_LOGS_URL|" "$ENV_FILE"
    
    # Verify the changes
    if grep -q "mysql+pymysql" "$ENV_FILE"; then
        log_message "✅ Successfully switched to MySQL URLs"
        return 0
    else
        log_message "❌ Failed to switch URLs"
        return 1
    fi
}

update_docker_compose() {
    log_message "🐳 Updating docker-compose.yaml ports..."
    
    local docker_compose_file="$OPENALGO_DIR/docker-compose.yaml"
    
    if [[ ! -f "$docker_compose_file" ]]; then
        log_message "⚠️ docker-compose.yaml not found, skipping port update"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "Would update docker-compose.yaml ports:"
        log_message "  Flask port: 2000:5000 (external:internal)"
        log_message "  WebSocket port: 2001:8765 (external:internal)"
        return 0
    fi
    
    # Update Flask port mapping
    if grep -q '\${FLASK_PORT:-5000}:5000' "$docker_compose_file"; then
        sed -i '' 's|\${FLASK_PORT:-5000}:5000|2000:5000|g' "$docker_compose_file" 2>/dev/null || sed -i 's|\${FLASK_PORT:-5000}:5000|2000:5000|g' "$docker_compose_file"
        log_message "  ✅ Updated Flask port mapping to 2000:5000"
    fi
    
    # Update WebSocket port mapping
    if grep -q '\${WEBSOCKET_PORT:-8765}:8765' "$docker_compose_file"; then
        sed -i '' 's|\${WEBSOCKET_PORT:-8765}:8765|2001:8765|g' "$docker_compose_file" 2>/dev/null || sed -i 's|\${WEBSOCKET_PORT:-8765}:8765|2001:8765|g' "$docker_compose_file"
        log_message "  ✅ Updated WebSocket port mapping to 2001:8765"
    fi
    
    # Verify the changes
    if grep -q '2000:5000' "$docker_compose_file" && grep -q '2001:8765' "$docker_compose_file"; then
        log_message "✅ Successfully updated docker-compose.yaml ports"
        return 0
    else
        log_message "❌ Failed to update docker-compose.yaml ports"
        return 1
    fi
}

update_requirements() {
    log_message "📦 Updating requirements.txt for MySQL support..."
    
    local requirements_file="$OPENALGO_DIR/requirements.txt"
    
    if [[ ! -f "$requirements_file" ]]; then
        log_message "⚠️ requirements.txt not found, skipping dependency update"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "Would add PyMySQL dependency to requirements.txt"
        if ! grep -qi "pymysql" "$requirements_file"; then
            log_message "  ➕ Would add: pymysql==1.1.1"
        else
            log_message "  ✅ PyMySQL already present in requirements.txt"
        fi
        return 0
    fi
    
    # Check if pymysql is already in requirements (case-insensitive)
    if grep -qi "pymysql" "$requirements_file"; then
        log_message "  ✅ PyMySQL already present in requirements.txt"
        return 0
    fi
    
    # Find SQLAlchemy line and add pymysql after it
    if grep -q "sqlalchemy==" "$requirements_file"; then
        # Add pymysql after sqlalchemy line
        sed -i '' '/sqlalchemy==/a\
pymysql==1.1.1' "$requirements_file" 2>/dev/null || sed -i '/sqlalchemy==/a\
pymysql==1.1.1' "$requirements_file"
        log_message "  ✅ Added pymysql==1.1.1 to requirements.txt"
    else
        # If no sqlalchemy found, add at the end
        echo "pymysql==1.1.1" >> "$requirements_file"
        log_message "  ✅ Added pymysql==1.1.1 to requirements.txt (at end)"
    fi
    
    # Verify the addition
    if grep -q "pymysql" "$requirements_file"; then
        log_message "✅ Successfully updated requirements.txt"
        return 0
    else
        log_message "❌ Failed to update requirements.txt"
        return 1
    fi
}

rollback() {
    log_message "🔄 Rolling back changes..."
    
    if [[ -f "$BACKUP_DIR/.env.backup" ]]; then
        cp "$BACKUP_DIR/.env.backup" "$ENV_FILE"
        log_message "✅ Restored .env file"
    fi
    
    # Restore database files
    for backup_db in "$BACKUP_DIR"/*.db; do
        if [[ -f "$backup_db" ]]; then
            cp "$backup_db" "$OPENALGO_DIR/db/"
            log_message "✅ Restored $(basename "$backup_db")"
        fi
    done
    
    log_message "✅ Rollback completed"
}

# Trap to handle errors
trap 'log_message "❌ Upgrade failed! Check logs above for details."; rollback; exit 1' ERR

########################################
# MAIN UPGRADE PROCESS
########################################
main() {
    log_message "🚀 Starting OpenAlgo upgrade process..."
    log_message "📁 OpenAlgo directory: $OPENALGO_DIR"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "🧪 DRY RUN MODE - No changes will be made"
    fi
    
    if [[ "$SWITCH_ONLY" == true ]]; then
        log_message "🔄 SWITCH-ONLY MODE - Only updating database URLs"
        check_dependencies
        create_backup
        switch_database_urls
        if [[ "$DRY_RUN" == false ]]; then
            log_message "✅ Database URLs switched successfully!"
            log_message "📦 Backup available at: $BACKUP_DIR"
        fi
        return 0
    fi
    
    check_dependencies
    create_backup
    
    ########################################
    # 1. Stash local changes
    ########################################
    log_message "📦 Stashing local changes..."
    cd "$OPENALGO_DIR"
    
    if [[ "$DRY_RUN" == false ]]; then
        git stash --include-untracked
    else
        log_message "Would stash local changes"
    fi

    ########################################
    # 2. Update from upstream
    ########################################
    log_message "⬇️ Pulling latest from upstream-main..."
    
    if [[ "$DRY_RUN" == false ]]; then
        git fetch upstream
        git checkout main
        git pull upstream main
    else
        log_message "Would fetch and pull from upstream"
    fi

    ########################################
    # 3. Merge into develop
    ########################################
    log_message "🔀 Merging main into develop..."
    
    if [[ "$DRY_RUN" == false ]]; then
        git checkout develop
        git merge main
    else
        log_message "Would merge main into develop"
    fi

    ########################################
    # 4. Prepare environment file
    ########################################
    log_message "📝 Removing existing .env and creating from sample..."
    
    if [[ "$DRY_RUN" == false ]]; then
        # Remove existing .env file if it exists
        if [[ -f "$ENV_FILE" ]]; then
            rm "$ENV_FILE"
            log_message "🗑️ Removed existing .env file"
        fi
        
        # Copy sample env to create new .env
        cp "$SAMPLE_ENV_FILE" "$ENV_FILE"
        log_message "📋 Created new .env from .sample.env"
    else
        log_message "Would remove existing .env and copy from sample"
    fi

    # Update .env with values from .update/.env
    log_message "🔄 Updating .env with configuration from $MY_ENV_FILE..."
    
    if [[ "$DRY_RUN" == false ]]; then
        while IFS='=' read -r key value
        do
            # Skip empty lines & comments
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)

            # Escape sed special characters in value
            safe_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')

            # Handle different types of configuration
            if [[ "$key" =~ ^MYSQL_ ]]; then
                # Add MySQL URLs as migration targets (don't replace SQLite URLs yet)
                if ! grep -q "^$key[ ]*=" "$ENV_FILE"; then
                    echo "$key = '$value'" >> "$ENV_FILE"
                    log_message "  ✅ Added migration target $key"
                fi
            else
                # Update or add any other configuration variable
                if grep -q "^$key[ ]*=" "$ENV_FILE"; then
                    # Update existing variable
                    sed -i '' "s|^$key[ ]*=.*|$key = '$value'|" "$ENV_FILE" 2>/dev/null || sed -i "s|^$key[ ]*=.*|$key = '$value'|" "$ENV_FILE"
                    log_message "  ✅ Updated $key"
                else
                    # Add new variable
                    echo "$key = '$value'" >> "$ENV_FILE"
                    log_message "  ✅ Added $key"
                fi
            fi
        done < "$MY_ENV_FILE"
        
        log_message "📋 .env prepared with custom configuration and SQLite URLs (MySQL URLs added as migration targets)"
    else
        log_message "Would update .env with custom configuration and add MySQL URLs as migration targets"
    fi

    ########################################
    # 5. Check and setup virtual environment
    ########################################
    if [[ ! -d "$VENV_PATH" ]]; then
        log_message "❌ Virtual environment not found at $VENV_PATH"
        log_message "Please create a virtual environment first: python -m venv .venv"
        exit 1
    fi

    ########################################
    # 6. Run migration script
    ########################################
    if [[ "$SKIP_MIGRATION" == false ]]; then
        log_message "🚀 Running migration script..."
        cd "$OPENALGO_DIR"
        
        if [[ "$DRY_RUN" == true ]]; then
            "$VENV_PATH/bin/python3" "$MIGRATION_SCRIPT" --dry-run
        else
            "$VENV_PATH/bin/python3" "$MIGRATION_SCRIPT"
        fi
    else
        log_message "⏭️ Skipping migration as requested"
    fi

    ########################################
    # 7. Switch to MySQL URLs (Final Step)
    ########################################
    log_message "🔄 Final step: Switching from SQLite to MySQL URLs in .env..."
    switch_database_urls

    ########################################
    # 8. Update Requirements for MySQL
    ########################################
    update_requirements

    ########################################
    # 9. Update Docker Compose Ports
    ########################################
    update_docker_compose

    ########################################
    if [[ "$DRY_RUN" == true ]]; then
        log_message "🧪 Dry run completed successfully!"
        log_message "Run without --dry-run to perform actual upgrade"
    else
        log_message "✅ Upgrade complete! Now running on MySQL."
        log_message "🐳 Docker ports updated: Flask(2000:5000), WebSocket(2001:8765)"
        log_message "📦 PyMySQL dependency added to requirements.txt"
        log_message "📦 Backup available at: $BACKUP_DIR"
    fi
}

# Run main function
main "$@"
