import json
import logging
import os
from datetime import datetime, timezone

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool
from prometheus_flask_exporter import PrometheusMetrics
from opentelemetry import trace


class JsonFormatter(logging.Formatter):
    def format(self, record):
        span_context = trace.get_current_span().get_span_context()
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": "ngo-service",
            "message": record.getMessage(),
            "trace_id": format(span_context.trace_id, "032x") if span_context.is_valid else None,
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
log = logging.getLogger("ngo-service")
log.handlers = [handler]
log.setLevel(os.getenv("LOG_LEVEL", "INFO"))
log.propagate = False


def create_app(pool=None):
    app = Flask(__name__)
    PrometheusMetrics(app, group_by="endpoint", defaults_prefix="solidarytech")
    app.config["DB_POOL"] = pool

    def db_pool():
        if app.config["DB_POOL"] is None:
            database_url = os.getenv("DATABASE_URL")
            if not database_url:
                raise RuntimeError("DATABASE_URL não definida")
            app.config["DB_POOL"] = ThreadedConnectionPool(1, 10, dsn=database_url)
        return app.config["DB_POOL"]

    @app.get("/health")
    @app.get("/health/live")
    def live():
        return jsonify({"status": "ok", "service": "ngo-service"})

    @app.get("/health/ready")
    def ready():
        try:
            connection = db_pool().getconn()
            try:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
            finally:
                db_pool().putconn(connection)
            return jsonify({"status": "ready", "service": "ngo-service"})
        except Exception as error:
            log.warning("readiness_failed: %s", error)
            return jsonify({"status": "not_ready", "service": "ngo-service"}), 503

    @app.post("/ngos")
    def create_ngo():
        data = request.get_json(silent=True) or {}
        if not isinstance(data, dict) or not all(
            data.get(field) for field in ("name", "email", "cause", "city")
        ):
            return jsonify({"error": "Campos obrigatórios ausentes"}), 400
        connection = db_pool().getconn()
        try:
            with connection.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute(
                    "INSERT INTO ngos (name, email, cause, city) VALUES (%s, %s, %s, %s) RETURNING *",
                    (data["name"], data["email"], data["cause"], data["city"]),
                )
                ngo = cursor.fetchone()
                connection.commit()
                return jsonify(ngo), 201
        except psycopg2.IntegrityError:
            connection.rollback()
            return jsonify({"error": "E-mail já cadastrado"}), 409
        except Exception as error:
            connection.rollback()
            log.exception("create_ngo_failed: %s", error)
            return jsonify({"error": "Erro interno"}), 500
        finally:
            db_pool().putconn(connection)

    @app.get("/ngos")
    def list_ngos():
        connection = db_pool().getconn()
        try:
            with connection.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("SELECT * FROM ngos ORDER BY id DESC")
                return jsonify(cursor.fetchall())
        except Exception as error:
            log.exception("list_ngos_failed: %s", error)
            return jsonify({"error": "Erro interno"}), 500
        finally:
            db_pool().putconn(connection)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8081")))  # nosec B104
