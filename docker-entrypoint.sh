#!/bin/sh
set -eu

APP_PORT="${APP_PORT:-8000}"

if [ ! -f /app/accounts.json ] && [ -f /app/accounts.example.json ]; then
  cp /app/accounts.example.json /app/accounts.json
fi

exec /app/zed2api serve "${APP_PORT}"
