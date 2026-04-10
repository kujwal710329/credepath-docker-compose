#!/bin/bash

# Usage: ./init-letsencrypt.sh [--staging]
# Pass --staging to use Let's Encrypt staging server (for testing)

set -e

DOMAINS=(acrapath.com www.acrapath.com)
EMAIL="${CERTBOT_EMAIL:-admin@acrapath.com}"  # Set via env var or change this default
COMPOSE_FILE="docker-compose.yml"
STAGING_ARG=""

if [ "$1" = "--staging" ]; then
  STAGING_ARG="--staging"
  echo "Using Let's Encrypt STAGING server (certs won't be trusted by browsers)"
fi

# Step 1: Create a dummy certificate so nginx can start
echo "### Creating dummy certificate for ${DOMAINS[0]} ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "\
  mkdir -p /etc/letsencrypt/live/${DOMAINS[0]}" certbot

docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout /etc/letsencrypt/live/${DOMAINS[0]}/privkey.pem \
    -out /etc/letsencrypt/live/${DOMAINS[0]}/fullchain.pem \
    -subj '/CN=localhost'" certbot

echo "### Starting nginx ..."
docker compose -f "$COMPOSE_FILE" up -d nginx

# Step 2: Delete the dummy certificate
echo "### Deleting dummy certificate ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "\
  rm -rf /etc/letsencrypt/live/${DOMAINS[0]} && \
  rm -rf /etc/letsencrypt/archive/${DOMAINS[0]} && \
  rm -rf /etc/letsencrypt/renewal/${DOMAINS[0]}.conf" certbot

# Step 3: Request the real certificate
echo "### Requesting Let's Encrypt certificate for ${DOMAINS[*]} ..."

DOMAIN_ARGS=""
for domain in "${DOMAINS[@]}"; do
  DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

docker compose -f "$COMPOSE_FILE" run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  --email "$EMAIL" \
  $DOMAIN_ARGS \
  --agree-tos \
  --no-eff-email \
  --force-renewal \
  $STAGING_ARG

echo "### Reloading nginx ..."
docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload

echo "### Done! SSL certificates have been obtained and nginx is running with HTTPS."
