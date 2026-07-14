FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /obelisk-api ./cmd/obelisk-api

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /obelisk-api /obelisk-api
ENTRYPOINT ["/obelisk-api"]
