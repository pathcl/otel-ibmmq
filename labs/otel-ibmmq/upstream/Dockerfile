FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -o upstream .

FROM alpine:3.19
WORKDIR /app
COPY --from=builder /app/upstream .
EXPOSE 8081
ENTRYPOINT ["./upstream"]
