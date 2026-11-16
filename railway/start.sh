#!/bin/sh
# Start script for Chamilo on Railway.
# First boot: runs Chamilo's own installer (step 6 of the web wizard) on a local-only
# port, so the public URL never shows an open install wizard. Every boot: syncs the
# database settings into .env, applies pending migrations (updates), starts Apache.
set -eu

APP=/var/www/chamilo
DIST_VAR=/var/www/chamilo-var.dist
DATA="${CHAMILO_DATA_DIR:-/data}"
export PORT="${PORT:-8080}"

log() { echo "[chamilo-railway] $*"; }
as_www() { su -s /bin/sh www-data -c "$*"; }

: "${DATABASE_HOST:?DATABASE_HOST is required}"
: "${DATABASE_NAME:?DATABASE_NAME is required}"
: "${DATABASE_USER:?DATABASE_USER is required}"
: "${DATABASE_PASSWORD:?DATABASE_PASSWORD is required}"
DATABASE_PORT="${DATABASE_PORT:-3306}"
export DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USER DATABASE_PASSWORD

# Railway's runtime can bring back mpm_event next to mpm_prefork; mod_php needs prefork only.
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*

# Persistent folders live on the volume; new files from an updated image are added,
# existing (customised) files are kept.
mkdir -p "$DATA/var" "$DATA/jwt"
for d in upload themes translations templates vue_templates; do
  mkdir -p "$DATA/var/$d"
  cp -an "$DIST_VAR/$d/." "$DATA/var/$d/" 2>/dev/null || true
  rm -rf "${APP:?}/var/$d"
  ln -sfn "$DATA/var/$d" "$APP/var/$d"
done
rm -rf "$APP/config/jwt"
ln -sfn "$DATA/jwt" "$APP/config/jwt"
mkdir -p "$APP/var/cache" "$APP/var/log"
find "$DATA" "$APP/var" -xdev ! -user www-data -exec chown -h www-data:www-data {} + 2>/dev/null || true

log "waiting for the database at $DATABASE_HOST:$DATABASE_PORT"
i=0
until php -r 'try { new PDO("mysql:host=".getenv("DATABASE_HOST").";port=".getenv("DATABASE_PORT"), getenv("DATABASE_USER"), getenv("DATABASE_PASSWORD"), [PDO::ATTR_TIMEOUT => 3]); } catch (Throwable $e) { exit(1); }' 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -ge 90 ] && { log "database not reachable after 180 s"; exit 1; }
  sleep 2
done

# set_env KEY VALUE FILE: replace or append KEY='VALUE' in a dotenv file.
set_env() { php /usr/local/bin/railway/set-env.php "$3" "$1" "$2"; }

if [ ! -f "$DATA/.env" ]; then
  : "${CHAMILO_ADMIN_PASSWORD:?CHAMILO_ADMIN_PASSWORD is required for the first install}"
  ADMIN_USER="${CHAMILO_ADMIN_USERNAME:-admin}"
  if [ -n "${CHAMILO_URL:-}" ]; then URL="$CHAMILO_URL"
  elif [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then URL="https://$RAILWAY_PUBLIC_DOMAIN/"
  else URL="http://localhost:$PORT/"; fi
  case "$URL" in */) ;; *) URL="$URL/";; esac
  HOST_PART=$(echo "$URL" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  ADMIN_EMAIL="${CHAMILO_ADMIN_EMAIL:-admin@$HOST_PART}"
  log "first boot: installing Chamilo $CHAMILO_VERSION for $URL (admin user: $ADMIN_USER)"

  rm -f "$APP/.env"
  as_www "cd $APP && APP_ENV=prod php -d max_execution_time=0 -d memory_limit=1024M -S 127.0.0.1:9100 -t public >/tmp/install-server.log 2>&1" &
  SRV=$!
  i=0; until curl -s -o /dev/null http://127.0.0.1:9100/favicon.ico; do i=$((i+1)); [ $i -ge 30 ] && break; sleep 1; done

  code=$(curl -sS --max-time 1200 -o /tmp/install.html -w '%{http_code}' -X POST \
    "http://127.0.0.1:9100/main/install/index.php?running=1&installType=new" \
    --data-urlencode "step6=1" \
    --data-urlencode "dbHostForm=$DATABASE_HOST" \
    --data-urlencode "dbPortForm=$DATABASE_PORT" \
    --data-urlencode "dbUsernameForm=$DATABASE_USER" \
    --data-urlencode "dbPassForm=$DATABASE_PASSWORD" \
    --data-urlencode "dbNameForm=$DATABASE_NAME" \
    --data-urlencode "loginForm=$ADMIN_USER" \
    --data-urlencode "passForm=$CHAMILO_ADMIN_PASSWORD" \
    --data-urlencode "emailForm=$ADMIN_EMAIL" \
    --data-urlencode "adminFirstName=${CHAMILO_ADMIN_FIRSTNAME:-Admin}" \
    --data-urlencode "adminLastName=${CHAMILO_ADMIN_LASTNAME:-Chamilo}" \
    --data-urlencode "adminPhoneForm=" \
    --data-urlencode "languageForm=${CHAMILO_LANGUAGE:-en_US}" \
    --data-urlencode "campusForm=${CHAMILO_PORTAL_NAME:-Chamilo}" \
    --data-urlencode "institutionForm=${CHAMILO_ORGANIZATION:-My Organisation}" \
    --data-urlencode "institutionUrlForm=$URL" \
    --data-urlencode "urlForm=$URL" \
    --data-urlencode "allowSelfReg=false" \
    --data-urlencode "allowSelfRegProf=0" \
    --data-urlencode "encryptPassForm=bcrypt" \
    --data-urlencode "installationProfile=" \
    --data-urlencode "mailerDsn=${MAILER_DSN:-null://null}" \
    --data-urlencode "mailerFromEmail=${MAILER_FROM_EMAIL:-$ADMIN_EMAIL}" \
    --data-urlencode "mailerFromName=${MAILER_FROM_NAME:-Chamilo}" || echo 000)
  kill "$SRV" 2>/dev/null || true
  sleep 1

  if ! grep -q "^APP_INSTALLED='1'" "$APP/.env" 2>/dev/null || \
     ! php -r '$p=new PDO("mysql:host=".getenv("DATABASE_HOST").";port=".getenv("DATABASE_PORT").";dbname=".getenv("DATABASE_NAME"), getenv("DATABASE_USER"), getenv("DATABASE_PASSWORD")); $s=$p->prepare("SELECT COUNT(*) FROM user WHERE username=?"); $s->execute([$argv[1]]); exit($s->fetchColumn() > 0 ? 0 : 1);' "$ADMIN_USER" 2>/dev/null; then
    log "installation failed (HTTP $code). Installer server log:"
    tail -n 60 /tmp/install-server.log || true
    rm -f "$APP/.env"
    exit 1
  fi
  log "installation finished (HTTP $code)"
  set_env JWT_PASSPHRASE "$(php -r 'echo bin2hex(random_bytes(24));')" "$APP/.env"
  mv "$APP/.env" "$DATA/.env"
fi

# Keep .env in line with the service variables on every boot.
ENVF="$DATA/.env"
set_env APP_ENV prod "$ENVF"
set_env APP_DEBUG 0 "$ENVF"
set_env TRUSTED_PROXIES "127.0.0.1,REMOTE_ADDR" "$ENVF"
set_env DATABASE_HOST "$DATABASE_HOST" "$ENVF"
set_env DATABASE_PORT "$DATABASE_PORT" "$ENVF"
set_env DATABASE_NAME "$DATABASE_NAME" "$ENVF"
set_env DATABASE_USER "$DATABASE_USER" "$ENVF"
set_env DATABASE_PASSWORD "$DATABASE_PASSWORD" "$ENVF"
chown www-data:www-data "$ENVF"; chmod 600 "$ENVF"
cp -p "$ENVF" "$APP/.env"

cd "$APP"
if [ ! -s "$DATA/jwt/private.pem" ]; then
  as_www "cd $APP && php -d memory_limit=-1 bin/console lexik:jwt:generate-keypair --skip-if-exists --no-interaction" || log "warning: could not generate the JWT key pair"
fi
log "applying pending database migrations"
as_www "cd $APP && php -d memory_limit=-1 bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration"
as_www "cd $APP && php -d memory_limit=-1 bin/console cache:clear --no-interaction" >/dev/null

log "starting Apache on port $PORT"
exec apache2-foreground
