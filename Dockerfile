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

# Install all required packages
RUN apt-get update && apt-get install -y \
    software-properties-common \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    && add-apt-repository ppa:ondrej/php \
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

# Create PHP configuration files
RUN echo "display_errors = On" > /etc/php/8.2/fpm/conf.d/99-extra.ini
RUN echo "display_errors = On" > /etc/php/8.2/cli/conf.d/99-extra.ini

# Configure PHP-FPM
RUN echo "catch_workers_output = On" >> /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "chdir = /var/www/html/public/" >> /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "php_admin_value[upload_max_filesize] = 100M" >> /etc/php/8.2/fpm/pool.d/www.conf && \
    echo "php_admin_value[post_max_size] = 100M" >> /etc/php/8.2/fpm/pool.d/www.conf

# Configure Nginx
RUN rm /etc/nginx/sites-enabled/default
COPY <<EOF /etc/nginx/sites-available/pterodactyl
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

RUN ln -s /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/

# Setup MariaDB
RUN service mariadb start && \
    mysql -e "CREATE DATABASE panel;" && \
    mysql -e "CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY 'thisisthepasswordforpterodactyl';" && \
    mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost';" && \
    mysql -e "FLUSH PRIVILEGES;"

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
    sed -i 's/REDIS_HOST=.*/REDIS_HOST=localhost/' .env

# Set permissions
RUN chown -R www-data:www-data /var/www/html && \
    chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Setup cron
RUN echo "* * * * * www-data /usr/bin/php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/pterodactyl && \
    chmod 0644 /etc/cron.d/pterodactyl

# Configure Supervisor
COPY <<EOF /etc/supervisor/conf.d/pterodactyl.conf
[supervisord]
nodaemon=true
user=root

[program:mariadb]
command=/usr/bin/mysqld_safe
user=mysql
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/mariadb.log
stderr_logfile=/var/log/supervisor/mariadb.log

[program:redis]
command=/usr/bin/redis-server
user=redis
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/redis.log
stderr_logfile=/var/log/supervisor/redis.log

[program:php-fpm]
command=/usr/sbin/php-fpm8.2 -F
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/php-fpm.log
stderr_logfile=/var/log/supervisor/php-fpm.log

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/nginx.log
stderr_logfile=/var/log/supervisor/nginx.log

[program:cron]
command=/usr/sbin/cron -f
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/cron.log
stderr_logfile=/var/log/supervisor/cron.log
EOF

# Create startup script
COPY <<EOF /start.sh
#!/bin/bash
set -e

# Start MariaDB
service mariadb start

# Wait for MariaDB to be ready
while ! mysqladmin ping --silent; do
    echo "Waiting for MariaDB..."
    sleep 2
done

# Generate application key if not exists
cd /var/www/html
if ! grep -q "APP_KEY=base64:" .env; then
    php artisan key:generate --force
fi

# Run migrations
php artisan migrate --force

# Seed database (only if tables are empty)
php artisan db:seed --force || true

# Fix permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache

# Start all services with supervisor
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/pterodactyl.conf
EOF

RUN chmod +x /start.sh

EXPOSE 80

CMD ["/start.sh"]
