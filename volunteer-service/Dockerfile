FROM python:3.12-slim AS build
WORKDIR /build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt

FROM python:3.12-slim
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid 10001 --home /app app
WORKDIR /app
COPY --from=build /wheels /wheels
COPY requirements.txt .
RUN pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt && rm -rf /wheels
COPY --chown=app:app app.py ./
USER 10001:10001
EXPOSE 8083
ENV PORT=8083 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 OTEL_SERVICE_NAME=volunteer-service OTEL_EXPORTER_OTLP_PROTOCOL=grpc
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8083/health/live')"
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8083", "--worker-tmp-dir", "/dev/shm", "--workers", "1", "--threads", "1", "app:app"]
