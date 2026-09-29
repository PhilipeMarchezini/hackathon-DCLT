FROM golang:1.25.7-alpine AS build
WORKDIR /src
RUN apk add --no-cache ca-certificates git
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/donation-service .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/donation-service /donation-service
EXPOSE 8082
ENV PORT=8082 OTEL_SERVICE_NAME=donation-service
USER nonroot:nonroot
ENTRYPOINT ["/donation-service"]
