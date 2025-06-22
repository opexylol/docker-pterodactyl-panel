# --- Stage 1: Download the Pterodactyl Panel source ---
FROM alpine AS download
ARG pterodactyl_panel_version=v1.11.10
RUN apk add --no-cache curl tar
RUN mkdir -p pterodactyl
RUN curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/download/${pterodactyl_panel_version}/panel.tar.gz
RUN tar -xzvf panel.tar.gz -C /pterodactyl

# --- Stage 2: PHP environment for building dependencies ---
FROM php:8.2-fpm-alpine AS base_php
RUN apk add --no-cache freetype-dev libjpeg-turbo-dev libpng-dev unzip libzip-dev git \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd bcmath pdo_mysql zip

# --- Stage 3: Install Composer dependencies ---
FROM base_php AS install_dependencies
WORKDIR /var/www/html
COPY --from=download /pterodactyl/ .
COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN composer install --no-dev --optimize-autoloader
ADD https://raw.githubusercontent.com/eficode/wait-for/master/wait-for /root/wait-for
RUN chmod +x /root/wait-for

# --- Stage 4: Final runtime image ---
FROM ubuntu:22.04

# Environment
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC

# Install required packages
RUN apt-get update && apt-get install -y \
    software-properties-common curl wget gnupg lsb-release ca-certificates \
    mariadb-server mariadb-client redis-server nginx \
    php8.2-fpm php8.2-mysql php8.2-zip php8.2-gd php8.2-mbstring \
    php8.2-curl php8.2-xml php8.2-bcmath php8.2-cli php8.2-intl php8.2-opcache \
    cron supervisor unzip git && \
    rm -rf /var/lib/apt/lists/*

# MariaDB config
RUN sed -i 's/^bind-address\s*=.*$/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf && \
    mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld

# Redis config
RUN sed -i 's/^bind .*/bind 0.0.0.0/' /etc/redis/redis.conf && \
    sed -i 's/^daemonize yes$/daemonize no/' /etc/redis/redis.conf && \
    sed -i 's/^supervised no$/supervised systemd/' /etc/redis/redis.conf && \
    mkdir -p /var/log/redis && chown redis:redis /var/log/redis

# PHP config
RUN echo "display_errors = On" > /etc/php/8.2/fpm/conf.d/99-extra.ini && \
    echo "upload_max_filesize = 100M\npost_max_size = 100M" >> /etc/php/8.2/fpm/conf.d/99-extra.ini && \
    echo "display_errors = On" > /etc/php/8.2/cli/conf.d/99-extra.ini

# PHP-FPM listen config
RUN sed -i 's/^listen = .*/listen = 127.0.0.1:9000/' /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "catch_workers_output = yes\nchdir = /var/www/html/public/" >> /etc/php/8.2/fpm/pool.d/www.conf

# Nginx site
RUN rm -f /etc/nginx/sites-enabled/default
COPY <<EOF /etc/nginx/sites-available/pterodactyl
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

RUN ln -s /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/

# Install Composer globally
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Pterodactyl files from previous stage
WORKDIR /var/www/html
COPY --from=install_dependencies --chown=www-data:www-data /var/www/html/ .
COPY --from=install_dependencies /var/www/html/.env.example .env

# Preconfigure .env
RUN sed -i 's/DB_HOST=.*/DB_HOST=localhost/' .env && \
    sed -i 's/DB_PORT=.*/DB_PORT=3306/' .env && \
    sed -i 's/DB_DATABASE=.*/DB_DATABASE=panel/' .env && \
    sed -i 's/DB_USERNAME=.*/DB_USERNAME=pterodactyl/' .env && \
    sed -i 's/DB_PASSWORD=.*/DB_PASSWORD=thisisthepasswordforpterodactyl/' .env && \
    sed -i 's/CACHE_DRIVER=.*/CACHE_DRIVER=redis/' .env && \
    sed -i 's/REDIS_HOST=.*/REDIS_HOST=localhost/' .env && \
    sed -i 's/REDIS_PORT=.*/REDIS_PORT=6379/' .env

# Permissions
RUN chown -R www-data:www-data /var/www/html && \
    chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Setup cron job
RUN echo "* * * * * www-data /usr/bin/php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/pterodactyl && \
    chmod 0644 /etc/cron.d/pterodactyl && \
    crontab /etc/cron.d/pterodactyl

# --- Startup Script ---
COPY <<EOF /start.sh
#!/bin/bash
set -e

# Start MariaDB
echo "Starting MariaDB..."
mysqld_safe --user=mysql --datadir=/var/lib/mysql &
MYSQL_PID=\$!

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
TIMEOUT=30
until mysqladmin ping --silent || [ \$TIMEOUT -eq 0 ]; do sleep 1; TIMEOUT=\$((TIMEOUT-1)); done
if [ \$TIMEOUT -eq 0 ]; then echo "MariaDB failed to start."; exit 1; fi

# Setup database if not initialized
if ! mysql -e "USE panel;" 2>/dev/null; then
    echo "Creating panel DB and user..."
    mysql -e "CREATE DATABASE panel;"
    mysql -e "CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY 'thisisthepasswordforpterodactyl';"
    mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
fi

# Start Redis
echo "Starting Redis..."
redis-server /etc/redis/redis.conf &

# Wait for Redis
echo "Waiting for Redis..."
until redis-cli ping | grep -q PONG; do sleep 1; done

# Laravel setup
cd /var/www/html

if ! grep -q "APP_KEY=base64:" .env; then
    echo "Generating Laravel key..."
    php artisan key:generate --force
fi

echo "Running migrations and seeders..."
php artisan migrate --force
php artisan db:seed --force || true

# Permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Start PHP-FPM, cron, Nginx
php-fpm8.2 &
cron &
nginx -g "daemon off;"
EOF

RUN chmod +x /start.sh

EXPOSE 80
CMD ["/start.sh"]
