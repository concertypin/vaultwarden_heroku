#!/usr/bin/env bash
set -euo pipefail

APP_NAME="valuting"
GIT_HASH="main"
VAULTWARDEN_REPO="https://github.com/dani-garcia/vaultwarden.git"

# Heroku Postgres add-on plan.
# If your account only offers a different plan name, change this one variable.
PG_PLAN="${PG_PLAN:-heroku-postgresql:mini}"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

ensure_app() {
  if heroku apps:info -a "$APP_NAME" >/dev/null 2>&1; then
    echo "App exists: $APP_NAME"
  else
    echo "Creating app: $APP_NAME"
    heroku create "$APP_NAME" >/dev/null
  fi
}

ensure_postgres() {
  if heroku config:get DATABASE_URL -a "$APP_NAME" >/dev/null 2>&1 && \
     [[ -n "$(heroku config:get DATABASE_URL -a "$APP_NAME" 2>/dev/null || true)" ]]; then
    echo "DATABASE_URL already present"
    return
  fi

  echo "Provisioning Heroku Postgres: $PG_PLAN"
  heroku addons:create "$PG_PLAN" -a "$APP_NAME"
}

ensure_base_config() {
  if [[ -z "$(heroku config:get ADMIN_TOKEN -a "$APP_NAME" 2>/dev/null || true)" ]]; then
    heroku config:set ADMIN_TOKEN="$(openssl rand -hex 32)" -a "$APP_NAME" >/dev/null
  fi

  heroku config:set \
    DOMAIN="https://${APP_NAME}.herokuapp.com" \
    SIGNUPS_ALLOWED=false \
    DATABASE_MAX_CONNS=7 \
    ENABLE_DB_WAL=false \
    I_REALLY_WANT_VOLATILE_STORAGE=true \
    -a "$APP_NAME" >/dev/null

  # Duo off
  heroku config:unset _ENABLE_DUO -a "$APP_NAME" >/dev/null 2>&1 || true

  # Autobus off
  autobus_addon="$(heroku addons -a "$APP_NAME" 2>/dev/null | awk '/autobus/ {print $1; exit}' || true)"
  if [[ -n "${autobus_addon:-}" ]]; then
    heroku addons:destroy "$autobus_addon" -a "$APP_NAME" -c >/dev/null || true
  fi
}

prepare_source() {
  git clone --depth 1 --branch "$GIT_HASH" "$VAULTWARDEN_REPO" "$tmpdir/vaultwarden" >/dev/null
  cd "$tmpdir/vaultwarden"

  # Original trick from the source script:
  # make Vaultwarden use Heroku's assigned $PORT.
  if ! grep -q 'export ROCKET_PORT=\$PORT' docker/start.sh; then
    sed -i '1 a export ROCKET_PORT=$PORT' docker/start.sh
  fi

  mv docker/amd64/Dockerfile Dockerfile
}

deploy() {
  ensure_app
  ensure_postgres
  ensure_base_config
  prepare_source

  heroku container:login
  heroku container:push web -a "$APP_NAME"
  heroku container:release web -a "$APP_NAME"
}

deploy
echo "Done: https://${APP_NAME}.herokuapp.com"
