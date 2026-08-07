FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN go build -o /traffic-gen .

FROM alpine:3.19
COPY --from=build /traffic-gen /traffic-gen
ENTRYPOINT ["/traffic-gen"]
