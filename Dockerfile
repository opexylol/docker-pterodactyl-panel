# Multi-stage build for Pterodactyl Panel
FROM alpine AS download
ARG pterodactyl_panel_version=v1.11.10
RUN apk add --no-cache \
        curl \
        tar
RUN mkdir -p pterodactyl
RUN curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/download/${pterodactyl_panel_version}/panel.tar.gz
RUN tar -xzvf panel.tar.gz -C /pterodactyl

# Base PHP setup
FROM php:8.2-fpm-alpine AS base_php
RUN apk add --no-cache \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        unzip \
        libzip-dev \
        git \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd \
    && docker-php-ext-install -j$(nproc) bcmath \
    && docker-php-ext-install -j$(nproc) pdo_mysql \
    && docker-php-ext-install -j$(nproc) zip

# Install PHP dependencies
FROM base_php AS install_dependencies
WORKDIR /var/www/html/
COPY --from=composer /usr/bin/composer /usr/bin/composer
COPY --from=download /pterodactyl/ .
RUN composer install --no-dev --optimize-autoloader
ADD https://raw.githubusercontent.com/eficode/wait-for/master/wait-for /root/wait-for
RUN chmod +x /root/wait-for

# Final unified image
FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install all required packages
RUN apt-get update && apt-get install -y \
    software-properties-common \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    && add-apt-repository ppa:ondrej/php -y \
    && apt-get update && apt-get install -y \
    # MariaDB
    mariadb-server \
    mariadb-client \
    # Redis
    redis-server \
    # Nginx
    nginx \
    # PHP and extensions
    php8.2-fpm \
    php8.2-mysql \
    php8.2-zip \
    php8.2-gd \
    php8.2-mbstring \
    php8.2-curl \
    php8.2-xml \
    php8.2-bcmath \
    php8.2-cli \
    php8.2-intl \
    php8.2-opcache \
    # Other utilities
    cron \
    supervisor \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Configure MariaDB
RUN sed -i 's/^bind-address\s*=.*$/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf && \
    mkdir -p /var/run/mysqld && \
    chown mysql:mysql /var/run/mysqld

# Configure Redis
RUN sed -i 's/^bind 127.0.0.1 ::1$/bind 0.0.0.0/' /etc/redis/redis.conf && \
    sed -i 's/^daemonize yes$/daemonize no/' /etc/redis/redis.conf && \
    sed -i 's/^supervised no$/supervised systemd/' /etc/redis/redis.conf && \
    mkdir -p /var/log/redis && \
    chown redis:redis /var/log/redis

# Create PHP configuration files
RUN echo "display_errors = On" > /etc/php/8.2/fpm/conf.d/99-extra.ini && \
    echo "display_errors = On" > /etc/php/8.2/cli/conf.d/99-extra.ini && \
    echo "upload_max_filesize = 100M" >> /etc/php/8.2/fpm/conf.d/99-extra.ini && \
    echo "post_max_size = 100M" >> /etc/php/8.2/fpm/conf.d/99-extra.ini

# Configure PHP-FPM
RUN sed -i 's/^listen = .*/listen = 127.0.0.1:9000/' /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "catch_workers_output = yes" >> /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "chdir = /var/www/html/public/" >> /etc/php/8.2/fpm/pool.d/www.conf

# Configure Nginx
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

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Setup Pterodactyl
WORKDIR /var/www/html
COPY --from=install_dependencies --chown=www-data:www-data /var/www/html/ .
COPY --from=install_dependencies /var/www/html/.env.example .env

# Configure environment variables for local services
RUN sed -i 's/DB_HOST=.*/DB_HOST=localhost/' .env && \
    sed -i 's/DB_PORT=.*/DB_PORT=3306/' .env && \
    sed -i 's/DB_DATABASE=.*/DB_DATABASE=panel/' .env && \
    sed -i 's/DB_USERNAME=.*/DB_USERNAME=pterodactyl/' .env && \
    sed -i 's/DB_PASSWORD=.*/DB_PASSWORD=thisisthepasswordforpterodactyl/' .env && \
    sed -i 's/CACHE_DRIVER=.*/CACHE_DRIVER=redis/' .env && \
    sed -i 's/REDIS_HOST=.*/REDIS_HOST=localhost/' .env && \
    sed -i 's/REDIS_PORT=.*/REDIS_PORT=6379/' .env

# Set permissions
RUN chown -R www-data:www-data /var/www/html && \
    chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Setup cron
RUN echo "* * * * * www-data /usr/bin/php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/pterodactyl && \
    chmod 0644 /etc/cron.d/pterodactyl && \
    crontab /etc/cron.d/pterodactyl

# Create initialization script
COPY <<EOF /init-db.sh
#!/bin/bash
set -e

# Initialize MariaDB
mysql_install_db --user=mysql --datadir=/var/lib/mysql

# Start MariaDB in background
mysqld_safe --user=mysql --datadir=/var/lib/mysql &
MYSQL_PID=\$!

# Wait for MariaDB to be ready
echo "Waiting for MariaDB to start..."
while ! mysqladmin ping --silent; do
    sleep 2
done

# Create database and user
mysql -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY 'thisisthepasswordforpterodactyl';"
mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Stop background MariaDB
kill \$MYSQL_PID
wait \$MYSQL_PID
EOF

RUN chmod +x /init-db.sh && /init-db.sh

# Create startup script
COPY <<EOF /start.sh
#!/bin/bash
set -e

# Start MariaDB
mysqld_safe --user=mysql --datadir=/var/lib/mysql &

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
while ! mysqladmin ping --silent; do sleep 1; done

# Initialize database on first run
if ! mysql -e "USE panel;" 2>/dev/null; then
    echo "Setting up database..."
    mysql -e "CREATE DATABASE panel;"
    mysql -e "CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY 'thisisthepasswordforpterodactyl';"
    mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
fi

# Start Redis
redis-server /etc/redis/redis.conf &

# Wait for Redis
echo "Waiting for Redis..."
while ! redis-cli ping > /dev/null 2>&1; do sleep 1; done

# Initialize Laravel
cd /var/www/html

# Generate app key if needed
if ! grep -q "APP_KEY=base64:" .env; then
    php artisan key:generate --force
fi

# Run migrations
php artisan migrate --force

# Seed database
php artisan db:seed --force || true

# Fix permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Start PHP-FPM
php-fpm8.2 &

# Start cron
cron &

# Start Nginx in foreground
nginx -g "daemon off;"
EOF

RUN chmod +x /start.sh

EXPOSE 80

CMD ["/start.sh"]
