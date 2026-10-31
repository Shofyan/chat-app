#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
container="ruang-chat-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --rm -d --name "$container" -e POSTGRES_USER=chat -e POSTGRES_PASSWORD=test_password -e POSTGRES_DB=chat_test -p 127.0.0.1::5432 postgres:17-alpine >/dev/null
for ((i=0; i<30; i++)); do
  if docker exec "$container" pg_isready -U chat -d chat_test >/dev/null 2>&1; then break; fi
  sleep 1
done
test_port=$(docker port "$container" 5432/tcp | cut -d: -f2)
export TEST_DATABASE_URL="postgres://chat:test_password@127.0.0.1:${test_port}/chat_test?sslmode=disable"
cd backend
go test -race -count=1 ./...
