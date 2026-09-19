FROM golang:1.25 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go fn.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /function .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /function /usr/local/bin/function
ENTRYPOINT ["/usr/local/bin/function"]
