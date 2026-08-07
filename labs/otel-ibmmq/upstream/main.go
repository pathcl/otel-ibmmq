package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/baggage"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var (
	gatewayURL string
	httpClient = &http.Client{Timeout: 5 * time.Second}
)

// initOtel configures the OTLP gRPC exporter and sets the global propagator to
// W3C TraceContext + W3C Baggage. Both must be present for downstream services
// to receive both traceparent and baggage headers.
func initOtel(ctx context.Context, serviceName, collectorEndpoint string) (func(), error) {
	// gRPC dial expects "host:port", not "http://host:port"
	endpoint := strings.TrimPrefix(collectorEndpoint, "http://")
	endpoint = strings.TrimPrefix(endpoint, "https://")

	conn, err := grpc.NewClient(endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("grpc dial %s: %w", endpoint, err)
	}

	exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		)),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return func() {
		sCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tp.Shutdown(sCtx)
		_ = conn.Close()
	}, nil
}

// handleOrder is the entry point of the distributed trace. It:
//  1. Creates a root span (no upstream context — this service owns the trace origin)
//  2. Sets tenant.id and user.id as W3C Baggage
//  3. Injects traceparent + baggage into the outbound HTTP request to the gateway
//
// The gateway and all MQ services downstream will receive this context and
// create child spans under the same trace ID.
func handleOrder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	tenantID := r.Header.Get("X-Tenant-ID")
	userID := r.Header.Get("X-User-ID")
	if tenantID == "" {
		http.Error(w, "X-Tenant-ID required", http.StatusBadRequest)
		return
	}
	if userID == "" {
		userID = "anonymous"
	}

	tracer := otel.Tracer("tutorial.upstream")
	ctx, span := tracer.Start(r.Context(), "upstream.order",
		trace.WithSpanKind(trace.SpanKindClient))
	defer span.End()

	span.SetAttributes(
		attribute.String("tenant.id", tenantID),
		attribute.String("user.id", userID),
	)

	// Baggage carries business context across process boundaries.
	// Every downstream service reads tenant.id from baggage rather than
	// parsing the message body or relying on custom headers.
	tenantMember, _ := baggage.NewMember("tenant.id", tenantID)
	userMember, _ := baggage.NewMember("user.id", userID)
	bag, _ := baggage.New(tenantMember, userMember)
	ctx = baggage.ContextWithBaggage(ctx, bag)

	// Build the outbound request to the gateway.
	// X-Tenant-ID / X-User-ID are kept so the gateway can validate them
	// independently of baggage (useful when gateway is also an entry point).
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, gatewayURL, strings.NewReader(""))
	if err != nil {
		span.RecordError(err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	req.Header.Set("X-Tenant-ID", tenantID)
	req.Header.Set("X-User-ID", userID)

	// Inject writes traceparent, tracestate, and baggage into req.Header.
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := httpClient.Do(req)
	if err != nil {
		span.RecordError(err)
		http.Error(w, "gateway unreachable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)

	log.Printf("upstream.order tenant=%-12s user=%-8s downstream=%d", tenantID, userID, resp.StatusCode)
}

func main() {
	port := flag.String("port", "8081", "listen port")
	flag.Parse()

	collectorEndpoint := env("OTEL_COLLECTOR_ENDPOINT", "http://localhost:4317")
	gatewayURL = env("GATEWAY_URL", "http://localhost:8080/send")
	serviceName := env("SERVICE_NAME", "upstream")

	ctx := context.Background()
	shutdown, err := initOtel(ctx, serviceName, collectorEndpoint)
	if err != nil {
		log.Fatalf("otel init: %v", err)
	}
	defer shutdown()

	http.HandleFunc("/order", handleOrder)
	log.Printf("upstream listening :%s  gateway=%s", *port, gatewayURL)
	log.Fatal(http.ListenAndServe(":"+*port, nil))
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
