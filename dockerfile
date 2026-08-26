# syntax=docker/dockerfile:1

FROM python:3.12-slim AS base

# Prevents Python from writing .pyc files and buffering stdout/stderr —
# the second one matters here so `docker compose logs` shows output live.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# System deps needed to build psycopg2 (Postgres driver) from source.
# Kept minimal on purpose — this is not a project that needs a heavy image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Install deps first, separately from app code, so code-only changes
# don't bust Docker's dependency-layer cache and force a full reinstall.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]