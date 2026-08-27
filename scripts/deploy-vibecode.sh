#!/usr/bin/env bash
set -euo pipefail

VIBE_URL="${VIBE_URL:-https://vibecode.bitrix24.tech}"
APP_NAME="${APP_NAME:-business-owner-cockpit}"
DISPLAY_NAME="${DISPLAY_NAME:-Business Owner Cockpit}"
DESCRIPTION="${DESCRIPTION:-Панель владельца бизнеса с ключевыми метриками для Битрикс24}"
PLAN="${PLAN:-bc-small}"
REGION="${REGION:-ru-central1-b}"
IMAGE="${IMAGE:-fd83esfomhq25p2ono90}"
RUNTIME="${RUNTIME:-static}"
PORT="${PORT:-3000}"

if [[ -z "${VIBE_API_KEY:-}" ]]; then
  echo "Ошибка: задайте VIBE_API_KEY в окружении, например:" >&2
  echo "  read -s VIBE_API_KEY && export VIBE_API_KEY" >&2
  exit 1
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Ошибка: требуется утилита '$1'." >&2
    exit 1
  fi
}

require_tool curl
require_tool python3
require_tool tar

TMP_DIR="$(mktemp -d)"
ARCHIVE="$TMP_DIR/app.tar.gz"
RESPONSE="$TMP_DIR/response.json"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

tar --exclude='.git' --exclude='node_modules' --exclude='.DS_Store' -czf "$ARCHIVE" index.html README.md

echo "Проверяю ключ Вайбкод..."
curl -fsS \
  -H "X-Api-Key: $VIBE_API_KEY" \
  "$VIBE_URL/v1/me" >/dev/null

echo "Создаю Black Hole сервер/приложение '$APP_NAME'..."
curl -fsS -X POST "$VIBE_URL/v1/infra/servers" \
  -H "X-Api-Key: $VIBE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 - <<PY
import json
print(json.dumps({
  "provider": "bitrix-cloud",
  "name": "$APP_NAME",
  "displayName": "$DISPLAY_NAME",
  "description": "$DESCRIPTION",
  "plan": "$PLAN",
  "region": "$REGION",
  "image": "$IMAGE",
}, ensure_ascii=False))
PY
)" > "$RESPONSE"

SERVER_ID="$(python3 - <<'PY' "$RESPONSE"
import json, sys
payload = json.load(open(sys.argv[1]))
print(payload.get('data', {}).get('id', ''))
PY
)"
SUBDOMAIN="$(python3 - <<'PY' "$RESPONSE"
import json, sys
payload = json.load(open(sys.argv[1]))
print(payload.get('data', {}).get('subdomain', ''))
PY
)"

if [[ -z "$SERVER_ID" ]]; then
  echo "Не удалось получить SERVER_ID. Ответ API:" >&2
  cat "$RESPONSE" >&2
  exit 1
fi

APP_URL="https://${SUBDOMAIN}.vibecode.bitrix24.tech"
echo "SERVER_ID=$SERVER_ID"
echo "APP_URL=$APP_URL"
echo "Жду готовности сервера и туннеля..."

for attempt in {1..60}; do
  curl -fsS -H "X-Api-Key: $VIBE_API_KEY" "$VIBE_URL/v1/infra/servers/$SERVER_ID" > "$RESPONSE"
  STATUS="$(python3 - <<'PY' "$RESPONSE"
import json, sys
payload = json.load(open(sys.argv[1]))
data = payload.get('data', {})
print(data.get('status', ''), data.get('blackholeStatus', ''))
PY
)"
  echo "  $attempt/60: $STATUS"
  if [[ "$STATUS" == "running CONNECTED" ]]; then
    break
  fi
  sleep 5
done

echo "Деплою приложение..."
curl -fsS -X POST "$VIBE_URL/v1/infra/servers/$SERVER_ID/deploy" \
  -H "X-Api-Key: $VIBE_API_KEY" \
  -F "file=@$ARCHIVE;type=application/gzip" \
  -F "runtime=$RUNTIME" \
  -F "port=$PORT" \
  -F "start=python3 -m http.server 3000" \
  -F "displayName=$DISPLAY_NAME" \
  -F "description=$DESCRIPTION" \
  -F "changelog=Первый деплой панели метрик собственника" \
  -F "cleanDeploy=true" \
  -F "healthPath=/" > "$RESPONSE"

echo "Готово: $APP_URL"
echo "Ответ деплоя сохранён во временном файле: $RESPONSE"
