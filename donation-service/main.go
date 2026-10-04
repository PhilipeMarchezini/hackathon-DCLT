package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type App struct {
	DB          *sql.DB
	Redis       *redis.Client
	SQS         *sqs.SQS
	SQSQueueURL string
}

var (
	httpRequests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "solidarytech_http_server_requests_total",
		Help: "Total de requisições HTTP do donation-service.",
	}, []string{"method", "route", "status"})
	httpDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "solidarytech_http_server_request_duration_seconds",
		Help:    "Duração das requisições HTTP do donation-service.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "route"})
	outboxPending = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "solidarytech_donation_outbox_pending",
		Help: "Quantidade de eventos de doação aguardando publicação.",
	})
	outboxFailed = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "solidarytech_donation_outbox_failed",
		Help: "Eventos que esgotaram as tentativas de publicacao.",
	})
)

func init() {
	prometheus.MustRegister(httpRequests, httpDuration, outboxPending, outboxFailed)
}

type responseRecorder struct {
	http.ResponseWriter
	status int
}

func (r *responseRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func observe(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		httpRequests.WithLabelValues(r.Method, route, strconv.Itoa(recorder.status)).Inc()
		httpDuration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	_ = godotenv.Load()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	shutdown, err := configureTelemetry(ctx, "donation-service")
	if err != nil {
		slog.Warn("telemetry_disabled", "error", err)
	} else {
		defer func() {
			telemetryCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = shutdown(telemetryCtx)
		}()
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		slog.Error("missing_configuration", "variable", "DATABASE_URL")
		return
	}
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		slog.Error("database_open_failed", "error", err)
		return
	}
	defer db.Close()

	app := &App{DB: db, SQSQueueURL: os.Getenv("AWS_SQS_URL")}
	if redisAddress := os.Getenv("REDIS_ADDR"); redisAddress != "" {
		app.Redis = redis.NewClient(&redis.Options{Addr: redisAddress})
	}
	if app.SQSQueueURL != "" {
		configuration := aws.NewConfig().WithRegion(env("AWS_REGION", "us-east-1"))
		if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
			configuration = configuration.WithEndpoint(endpoint).WithS3ForcePathStyle(true)
		}
		sess, sessionErr := session.NewSession(configuration)
		if sessionErr != nil {
			slog.Error("aws_session_failed", "error", sessionErr)
			return
		}
		app.SQS = sqs.New(sess)
		go app.publishOutbox(ctx)
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/health", observe("/health", http.HandlerFunc(app.LiveHandler)))
	mux.Handle("/health/live", observe("/health/live", http.HandlerFunc(app.LiveHandler)))
	mux.Handle("/health/ready", observe("/health/ready", http.HandlerFunc(app.ReadyHandler)))
	mux.Handle("/donations", observe("/donations", http.HandlerFunc(app.DonationHandler)))

	port := env("PORT", "8082")
	server := &http.Server{
		Addr:              ":" + port,
		Handler:           otelhttp.NewHandler(mux, "donation-http"),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	slog.Info("service_started", "service", "donation-service", "port", port)
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if shutdownErr := server.Shutdown(shutdownCtx); shutdownErr != nil {
			slog.Error("server_shutdown_failed", "error", shutdownErr)
		}
	}()
	if err = server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server_failed", "error", err)
	}
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func (a *App) LiveHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": "donation-service"})
}

func (a *App) ReadyHandler(w http.ResponseWriter, r *http.Request) {
	if a.DB == nil || a.DB.PingContext(r.Context()) != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not_ready", "service": "donation-service"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready", "service": "donation-service"})
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		a.createDonation(w, r)
	case http.MethodGet:
		a.listDonations(w, r)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "Método não permitido"})
	}
}

func (a *App) createDonation(w http.ResponseWriter, r *http.Request) {
	var donation Donation
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&donation); err != nil || donation.NgoID <= 0 || donation.Amount <= 0 || donation.DonorName == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Payload inválido"})
		return
	}
	if a.DB == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Banco indisponível"})
		return
	}
	donation.Status = "APPROVED"
	tx, err := a.DB.BeginTx(r.Context(), nil)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	defer tx.Rollback()
	if err = tx.QueryRowContext(r.Context(),
		"INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
		donation.NgoID, donation.Amount, donation.DonorName, donation.Status,
	).Scan(&donation.ID, &donation.CreatedAt); err != nil {
		slog.ErrorContext(r.Context(), "donation_insert_failed", "error", err, "trace_id", traceID(r.Context()))
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	payload, _ := json.Marshal(donation)
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(r.Context(), carrier)
	if _, err = tx.ExecContext(r.Context(),
		"INSERT INTO donation_outbox (donation_id, payload, traceparent) VALUES ($1, $2, $3)",
		donation.ID, payload, carrier.Get("traceparent"),
	); err != nil {
		slog.ErrorContext(r.Context(), "outbox_insert_failed", "error", err, "trace_id", traceID(r.Context()))
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	if err = tx.Commit(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	if a.Redis != nil {
		_ = a.Redis.Del(r.Context(), "donations:latest").Err()
	}
	writeJSON(w, http.StatusCreated, donation)
}

func (a *App) listDonations(w http.ResponseWriter, r *http.Request) {
	if a.Redis != nil {
		if cached, err := a.Redis.Get(r.Context(), "donations:latest").Bytes(); err == nil {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Cache", "HIT")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(cached)
			return
		}
	}
	if a.DB == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Banco indisponível"})
		return
	}
	rows, err := a.DB.QueryContext(r.Context(), "SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC LIMIT 100")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	defer rows.Close()
	donations := make([]Donation, 0)
	for rows.Next() {
		var donation Donation
		if err = rows.Scan(&donation.ID, &donation.NgoID, &donation.Amount, &donation.DonorName, &donation.Status, &donation.CreatedAt); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
			return
		}
		donations = append(donations, donation)
	}
	if err = rows.Err(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Erro interno"})
		return
	}
	data, _ := json.Marshal(donations)
	if a.Redis != nil {
		_ = a.Redis.Set(r.Context(), "donations:latest", data, 30*time.Second).Err()
	}
	w.Header().Set("X-Cache", "MISS")
	writeJSON(w, http.StatusOK, donations)
}

func (a *App) publishOutbox(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := a.publishBatch(ctx); err != nil {
				slog.ErrorContext(ctx, "outbox_publish_failed", "error", err)
			}
		}
	}
}

func (a *App) publishBatch(ctx context.Context) error {
	if a.DB == nil || a.SQS == nil || a.SQSQueueURL == "" {
		return nil
	}
	var pending, failed int
	if err := a.DB.QueryRowContext(ctx, "SELECT COUNT(*), COUNT(*) FILTER (WHERE attempts >= 10) FROM donation_outbox WHERE published = FALSE").Scan(&pending, &failed); err != nil {
		return err
	}
	outboxPending.Set(float64(pending))
	outboxFailed.Set(float64(failed))
	tx, err := a.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT id, payload, COALESCE(traceparent, '') FROM donation_outbox WHERE published = FALSE AND attempts < 10 ORDER BY id LIMIT 20 FOR UPDATE SKIP LOCKED")
	if err != nil {
		return err
	}
	defer rows.Close()
	type event struct {
		id                   int64
		payload, traceparent string
	}
	events := make([]event, 0)
	for rows.Next() {
		var item event
		if scanErr := rows.Scan(&item.id, &item.payload, &item.traceparent); scanErr != nil {
			return scanErr
		}
		events = append(events, item)
	}
	if err = rows.Err(); err != nil {
		return err
	}
	if err = rows.Close(); err != nil {
		return err
	}
	for _, item := range events {
		input := &sqs.SendMessageInput{QueueUrl: aws.String(a.SQSQueueURL), MessageBody: aws.String(item.payload)}
		if item.traceparent != "" {
			input.MessageAttributes = map[string]*sqs.MessageAttributeValue{
				"traceparent": {DataType: aws.String("String"), StringValue: aws.String(item.traceparent)},
			}
		}
		_, sendErr := a.SQS.SendMessageWithContext(ctx, input)
		if sendErr != nil {
			if _, updateErr := tx.ExecContext(ctx, "UPDATE donation_outbox SET attempts = attempts + 1 WHERE id = $1", item.id); updateErr != nil {
				return updateErr
			}
			continue
		}
		if _, updateErr := tx.ExecContext(ctx, "UPDATE donation_outbox SET published = TRUE, published_at = NOW(), attempts = attempts + 1 WHERE id = $1", item.id); updateErr != nil {
			return updateErr
		}
	}
	return tx.Commit()
}

func traceID(ctx context.Context) string {
	spanContext := trace.SpanFromContext(ctx).SpanContext()
	if !spanContext.IsValid() {
		return ""
	}
	return spanContext.TraceID().String()
}

var errTelemetryEndpoint = errors.New("OTEL_EXPORTER_OTLP_ENDPOINT não configurado")

func telemetryEndpoint() (string, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return "", errTelemetryEndpoint
	}
	return endpoint, nil
}
