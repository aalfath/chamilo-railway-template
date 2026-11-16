# Chamilo LMS for Railway: official release zip on the official PHP Apache image.
# Upstream publishes no Docker image, so this builds the release package as documented in
# https://github.com/chamilo/chamilo-lms#quick-install

FROM php:8.4.27-apache-trixie@sha256:884f64b47174de2c0e813270fe7b24a18605729fcebe201302d98c38805530d0 AS fetch
ARG CHAMILO_VERSION=3.0.2
ARG CHAMILO_SHA256=c54055f1754b377287c8e73880d2b967128b6d6a86bf3b91262f56cb4df855cf
RUN set -eux; \
    apt-get update; apt-get install -y --no-install-recommends unzip; \
    curl -fsSL -o /tmp/chamilo.zip "https://github.com/chamilo/chamilo-lms/releases/download/v${CHAMILO_VERSION}/chamilo-${CHAMILO_VERSION}.zip"; \
    echo "${CHAMILO_SHA256}  /tmp/chamilo.zip" | sha256sum -c -; \
    mkdir -p /src; unzip -q /tmp/chamilo.zip -d /src; \
    rm -rf /src/tests /src/.github /src/CLAUDE.md /src/.claude

FROM php:8.4.27-apache-trixie@sha256:884f64b47174de2c0e813270fe7b24a18605729fcebe201302d98c38805530d0
ARG CHAMILO_VERSION=3.0.2
ARG APCU_VERSION=5.1.28
ENV CHAMILO_VERSION=${CHAMILO_VERSION}

RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libicu-dev libzip-dev \
        libxml2-dev libldap2-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli zip intl gd exif soap bcmath opcache ldap; \
    curl -fsSL -o /tmp/apcu.tgz "https://github.com/krakjoe/apcu/archive/refs/tags/v${APCU_VERSION}.tar.gz"; \
    mkdir -p /usr/src/php/ext/apcu; tar xzf /tmp/apcu.tgz -C /usr/src/php/ext/apcu --strip-components=1; \
    docker-php-ext-install -j"$(nproc)" apcu; rm -f /tmp/apcu.tgz; \
    apt-mark auto '.*' > /dev/null; apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u | xargs -r dpkg-query --search | cut -d: -f1 | sort -u | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/* /usr/src/php/ext/apcu; \
    php -m | grep -qi apcu; php -m | grep -qi intl; php -m | grep -qi gd

COPY --from=fetch --chown=www-data:www-data /src /var/www/chamilo
COPY railway/apache-chamilo.conf /etc/apache2/sites-available/000-default.conf
COPY railway/php-chamilo.ini /usr/local/etc/php/conf.d/zz-chamilo.ini
COPY --chown=www-data:www-data railway/healthz.php /var/www/chamilo/public/healthz.php
COPY railway/start.sh railway/set-env.php /usr/local/bin/railway/

RUN set -eux; \
    a2enmod rewrite headers expires setenvif; \
    : > /etc/apache2/ports.conf; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    chmod +x /usr/local/bin/railway/start.sh; \
    cp -a /var/www/chamilo/var /var/www/chamilo-var.dist

WORKDIR /var/www/chamilo
ENV PORT=8080
EXPOSE 8080
CMD ["/usr/local/bin/railway/start.sh"]
