FROM mariadb:10.5

# MariaDB runs on standard port 3306 inside container
# Port mapping 3307:3306 is handled in docker-compose.yml
EXPOSE 3306

# Ensure proper charset and collation for international sports data
ENV MYSQL_CHARSET=utf8mb4
ENV MYSQL_COLLATION=utf8mb4_unicode_ci
