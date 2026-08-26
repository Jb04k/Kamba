
set -euo pipefail

# Wait for Postgres to actually accept connections before Django tries to
# migrate against it — without this, a fast `docker compose up` on a cold
# start will crash-loop the web container while Postgres is still booting.
echo "Waiting for Postgres at ${POSTGRES_HOST:-db}:${POSTGRES_PORT:-5432}..."
until python - <<'PYEOF'
import os
import socket
import sys

host = os.environ.get("POSTGRES_HOST", "db")
port = int(os.environ.get("POSTGRES_PORT", "5432"))

try:
    with socket.create_connection((host, port), timeout=2):
        sys.exit(0)
except OSError:
    sys.exit(1)
PYEOF
do
  sleep 1
done
echo "Postgres is up."

# Migrations run on every container start. Safe because Django migrations
# are idempotent (no-op if already applied) — this keeps `docker compose up`
# a true one-command bootstrap on a fresh clone.
python manage.py migrate --noinput

exec "$@"