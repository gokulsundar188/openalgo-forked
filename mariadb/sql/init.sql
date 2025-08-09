-- CREATE DATABASES FIRST
CREATE DATABASE IF NOT EXISTS openalgo;
CREATE DATABASE IF NOT EXISTS openalgo_logs;
CREATE DATABASE IF NOT EXISTS openalgo_latency;

-- Create user for both local and remote connections
CREATE USER IF NOT EXISTS 'dbuser'@'localhost' IDENTIFIED BY 'aa123456';
CREATE USER IF NOT EXISTS 'dbuser'@'%' IDENTIFIED BY 'aa123456';

-- Update password (optional if already specified above)
-- ALTER USER 'dbuser'@'localhost' IDENTIFIED BY 'aa123456';
-- ALTER USER 'dbuser'@'%' IDENTIFIED BY 'aa123456';

-- Grant privileges for databases
GRANT ALL PRIVILEGES ON `openalgo`.* TO 'dbuser'@'localhost';
GRANT ALL PRIVILEGES ON `openalgo`.* TO 'dbuser'@'%';

GRANT ALL PRIVILEGES ON `openalgo_logs`.* TO 'dbuser'@'localhost';
GRANT ALL PRIVILEGES ON `openalgo_logs`.* TO 'dbuser'@'%';

GRANT ALL PRIVILEGES ON `openalgo_latency`.* TO 'dbuser'@'localhost';
GRANT ALL PRIVILEGES ON `openalgo_latency`.* TO 'dbuser'@'%';

-- Apply privilege changes
FLUSH PRIVILEGES;
