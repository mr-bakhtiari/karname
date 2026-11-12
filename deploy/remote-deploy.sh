#!/bin/sh
set -eu

APP_DIR=/opt/karname-portal
CADDY_DIR=/root/shajare-portal
CADDY_CONTAINER=shajare-caddy-1
FRONTEND_NETWORK=shajare_frontend

test -f "$APP_DIR/compose.yaml"
test -f "$APP_DIR/deploy/Caddyfile.karname"
test -f "$CADDY_DIR/Caddyfile"
docker network inspect "$FRONTEND_NETWORK" >/dev/null

cd "$APP_DIR"
docker compose config --quiet
docker compose build --pull web
docker compose up -d --remove-orphans

container_id=$(docker compose ps -q web)
test -n "$container_id"

attempt=0
while [ "$attempt" -lt 30 ]; do
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")
  if [ "$health" = healthy ]; then
    break
  fi
  if [ "$health" = unhealthy ] || [ "$health" = exited ] || [ "$health" = dead ]; then
    docker compose logs --tail=100 web
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 2
done

health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")
test "$health" = healthy

candidate=$(mktemp "$CADDY_DIR/Caddyfile.karname.XXXXXX")
backup="$CADDY_DIR/Caddyfile.backup.$(date -u +%Y%m%dT%H%M%SZ)"

awk '
  /# BEGIN KARNAME PORTAL/ { skip=1; next }
  /# END KARNAME PORTAL/ { skip=0; next }
  !skip { print }
' "$CADDY_DIR/Caddyfile" > "$candidate"
printf '\n' >> "$candidate"
cat "$APP_DIR/deploy/Caddyfile.karname" >> "$candidate"

docker run --rm \
  -v "$candidate:/etc/caddy/Caddyfile:ro" \
  caddy:2.10-alpine \
  caddy validate --config /etc/caddy/Caddyfile

cp "$CADDY_DIR/Caddyfile" "$backup"
cp "$candidate" "$CADDY_DIR/Caddyfile"
rm -f "$candidate"

if ! docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile; then
  cp "$backup" "$CADDY_DIR/Caddyfile"
  docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile
  exit 1
fi

if ! docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile; then
  cp "$backup" "$CADDY_DIR/Caddyfile"
  docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile
  exit 1
fi

docker exec "$CADDY_CONTAINER" wget -q -O /dev/null http://karname-web:8080/

attempt=0
while [ "$attempt" -lt 30 ]; do
  if curl --resolve karname.mrbakhtiari.com:443:127.0.0.1 \
    --fail --silent --show-error --max-time 10 \
    https://karname.mrbakhtiari.com/ | grep -q 'کارنامه‌ساز مدرسه'; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

test "$attempt" -lt 30
docker compose ps
printf 'ORIGIN_HTTPS_OK\n'
