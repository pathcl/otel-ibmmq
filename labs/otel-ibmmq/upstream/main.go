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

// headerToBaggageKey derives the W3C Baggage key from an HTTP header name.
// Go's net/http canonicalises header names (X-Tenant-ID → X-Tenant-Id), so
// we strip "X-", lowercase, and replace "-" with ".":
//
//	X-Tenant-Id → tenant.id
//	X-User-Id   → user.id
//	X-Region-Id → region.id
func headerToBaggageKey(header string) string {
	return strings.ToLower(strings.ReplaceAll(header[2:], "-", "."))
}

// handleOrder is the entry point of the distributed trace. It collects every
// X-* header from the incoming request, forwards them all as W3C Baggage to
// the gateway, and injects traceparent + baggage into the outbound HTTP call.
//
// Adding a new propagated attribute requires no code change — just send the
// corresponding X-* header and it flows through the entire pipeline.
func handleOrder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Collect all X-* headers. Go's HTTP server canonicalises header names, so
	// X-Tenant-ID arrives as X-Tenant-Id and derives to tenant.id.
	attrs := map[string]string{}
	for name, vals := range r.Header {
		if strings.HasPrefix(name, "X-") && len(vals) > 0 {
			attrs[headerToBaggageKey(name)] = vals[0]
		}
	}

	tenantID := attrs["tenant.id"]
	if tenantID == "" {
		http.Error(w, "X-Tenant-ID required", http.StatusBadRequest)
		return
	}
	userID := attrs["user.id"]
	if userID == "" {
		userID = "anonymous"
		attrs["user.id"] = userID
	}

	tracer := otel.Tracer("tutorial.upstream")
	ctx, span := tracer.Start(r.Context(), "upstream.order",
		trace.WithSpanKind(trace.SpanKindClient))
	defer span.End()

	// Set all collected values as span attributes.
	for k, v := range attrs {
		span.SetAttributes(attribute.String(k, v))
	}

	// Build W3C Baggage from all collected X-* headers.
	var members []baggage.Member
	for k, v := range attrs {
		m, err := baggage.NewMember(k, v)
		if err != nil {
			log.Printf("skipping baggage key %q: %v", k, err)
			continue
		}
		members = append(members, m)
	}
	bag, _ := baggage.New(members...)
	ctx = baggage.ContextWithBaggage(ctx, bag)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, gatewayURL, strings.NewReader(""))
	if err != nil {
		span.RecordError(err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Forward all X-* headers to the gateway so it can validate them
	// independently (useful when gateway is also used as a standalone entry point).
	for name, vals := range r.Header {
		if strings.HasPrefix(name, "X-") {
			for _, v := range vals {
				req.Header.Add(name, v)
			}
		}
	}

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
