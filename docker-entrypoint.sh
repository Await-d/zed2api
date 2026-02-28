#!/bin/sh
set -eu

APP_PORT="${APP_PORT:-8000}"
APP_INTERNAL_PORT="${APP_INTERNAL_PORT:-18000}"

if [ ! -f /app/accounts.json ] && [ -f /app/accounts.example.json ]; then
  cp /app/accounts.example.json /app/accounts.json
fi

/app/zed2api serve "${APP_INTERNAL_PORT}" &
APP_PID=$!

cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

exec socat TCP-LISTEN:"${APP_PORT}",fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"${APP_INTERNAL_PORT}"
