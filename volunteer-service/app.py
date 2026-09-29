import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from flask import Flask, jsonify, request
from opentelemetry import trace
from prometheus_flask_exporter import PrometheusMetrics


class JsonFormatter(logging.Formatter):
    def format(self, record):
        span_context = trace.get_current_span().get_span_context()
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": "volunteer-service",
            "message": record.getMessage(),
            "trace_id": format(span_context.trace_id, "032x") if span_context.is_valid else None,
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
log = logging.getLogger("volunteer-service")
log.handlers = [handler]
log.setLevel(os.getenv("LOG_LEVEL", "INFO"))
log.propagate = False


def create_app(table=None):
    app = Flask(__name__)
    PrometheusMetrics(app, group_by="endpoint", defaults_prefix="solidarytech")
    app.config["DYNAMODB_TABLE"] = table

    def volunteers_table():
        if app.config["DYNAMODB_TABLE"] is None:
            table_name = os.getenv("AWS_DYNAMODB_TABLE")
            if not table_name:
                raise RuntimeError("AWS_DYNAMODB_TABLE não definida")
            options = {"region_name": os.getenv("AWS_REGION", "us-east-1")}
            if os.getenv("AWS_ENDPOINT_URL"):
                options["endpoint_url"] = os.getenv("AWS_ENDPOINT_URL")
            app.config["DYNAMODB_TABLE"] = boto3.resource("dynamodb", **options).Table(table_name)
        return app.config["DYNAMODB_TABLE"]

    @app.get("/health")
    @app.get("/health/live")
    def live():
        return jsonify({"status": "ok", "service": "volunteer-service"})

    @app.get("/health/ready")
    def ready():
        try:
            volunteers_table().load()
            return jsonify({"status": "ready", "service": "volunteer-service"})
        except Exception as error:
            log.warning("readiness_failed: %s", error)
            return jsonify({"status": "not_ready", "service": "volunteer-service"}), 503

    @app.post("/volunteers")
    def register_volunteer():
        data = request.get_json(silent=True) or {}
        if not isinstance(data, dict) or not all(
            data.get(field) for field in ("name", "email", "ngo_id")
        ):
            return jsonify({"error": "Campos obrigatórios ausentes"}), 400
        try:
            ngo_id = int(data["ngo_id"])
        except (TypeError, ValueError):
            return jsonify({"error": "ngo_id deve ser inteiro"}), 400
        if ngo_id <= 0:
            return jsonify({"error": "ngo_id deve ser positivo"}), 400
        item = {
            "volunteer_id": str(uuid.uuid4()),
            "name": str(data["name"]),
            "email": str(data["email"]),
            "ngo_id": ngo_id,
            "registered_at": str(int(time.time())),
        }
        try:
            volunteers_table().put_item(Item=item)
            return jsonify(item), 201
        except Exception as error:
            log.exception("register_volunteer_failed: %s", error)
            return jsonify({"error": "Erro interno ao processar dados"}), 500

    @app.get("/volunteers/<int:ngo_id>")
    def volunteers_by_ngo(ngo_id):
        try:
            result = volunteers_table().query(
                IndexName="ngo_id-index", KeyConditionExpression=Key("ngo_id").eq(ngo_id)
            )
            return jsonify(result.get("Items", []))
        except Exception as error:
            log.exception("list_volunteers_failed: %s", error)
            return jsonify({"error": "Erro interno"}), 500

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8083")))  # nosec B104
