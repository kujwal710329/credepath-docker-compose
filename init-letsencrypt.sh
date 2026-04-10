#!/bin/bash

# Usage: ./init-letsencrypt.sh <environment> [--staging]
#   environment: 'staging' or 'production'
#   --staging: Use Let's Encrypt staging server (for testing, certs won't be trusted)
#
# Examples:
#   ./init-letsencrypt.sh staging              # Get real certs for stag.acrapath.com
#   ./init-letsencrypt.sh staging --staging    # Test with Let's Encrypt staging server
#   ./init-letsencrypt.sh production           # Get real certs for acrapath.com

set -e

# Check for environment argument
if [ -z "$1" ] || { [ "$1" != "staging" ] && [ "$1" != "production" ]; }; then
  echo "Usage: ./init-letsencrypt.sh <environment> [--staging]"
  echo "  environment: 'staging' or 'production'"
  echo "  --staging: Use Let's Encrypt staging server (for testing)"
  echo ""
  echo "Examples:"
  echo "  ./init-letsencrypt.sh staging              # Get real certs for stag.acrapath.com"
  echo "  ./init-letsencrypt.sh staging --staging    # Test with LE staging server"
  echo "  ./init-letsencrypt.sh production           # Get real certs for acrapath.com"
  exit 1
fi

ENVIRONMENT=$1
shift

# Set domains based on environment
if [ "$ENVIRONMENT" = "staging" ]; then
  DOMAINS=(stag.acrapath.com www.stag.acrapath.com)
  NGINX_CONF="nginx/nginx-staging.conf"
else
  DOMAINS=(acrapath.com www.acrapath.com)
  NGINX_CONF="nginx/nginx-production.conf"
fi

EMAIL="${CERTBOT_EMAIL:-contact@acrapath.com}"
COMPOSE_FILE="docker-compose.yml"
STAGING_ARG=""
RSA_KEY_SIZE=4096

if [ "$1" = "--staging" ]; then
  STAGING_ARG="--staging"
  echo "Using Let's Encrypt STAGING server (certs won't be trusted by browsers)"
fi

echo "### Setting up SSL for $ENVIRONMENT environment"
echo "### Domains: ${DOMAINS[*]}"
echo ""

# Copy the appropriate nginx config
echo "### Copying $ENVIRONMENT nginx config ..."
cp "$NGINX_CONF" nginx/nginx.conf

echo "### Stopping any running nginx container ..."
docker compose -f "$COMPOSE_FILE" stop nginx 2>/dev/null || true

# Step 1: Create a dummy certificate so nginx can start
echo "### Creating dummy certificate for ${DOMAINS[0]} ..."
docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "\
  mkdir -p /etc/letsencrypt/live/${DOMAINS[0]}" certbot

docker compose -f "$COMPOSE_FILE" run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1 \
    -keyout /etc/letsencrypt/live/${DOMAINS[0]}/privkey.pem \
    -out /etc/letsencrypt/live/${DOMAINS[0]}/fullchain.pem \
    -subj '/CN=localhost'" certbot

echo "### Starting nginx with SSL config ..."
docker compose -f "$COMPOSE_FILE" up -d nginx

# Wait for nginx to start
echo "### Waiting for nginx to be ready ..."
sleep 5

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
  --rsa-key-size $RSA_KEY_SIZE \
  $DOMAIN_ARGS \
  --agree-tos \
  --no-eff-email \
  --force-renewal \
  $STAGING_ARG

echo "### Reloading nginx ..."
docker compose -f "$COMPOSE_FILE" exec nginx nginx -s reload

echo ""
echo "### Done! SSL certificates have been obtained for $ENVIRONMENT environment."
echo "### Your site should now be accessible at https://${DOMAINS[0]}"
