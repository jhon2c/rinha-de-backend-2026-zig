# Rinha de Backend 2026 — Zig

Fraud-detection API for the [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026)
challenge, in Zig. It vectorizes each transaction into 14 normalized dimensions,
finds the 5 nearest reference vectors among the 3,000,000 references, and returns
`approved = (frauds_among_5 / 5) < 0.6`.

Endpoints (port 9999): `GET /ready`, `POST /fraud-score`.

## Layout

```
src/
  vec.zig          vectorizer, quantization, distance, top-5
  index.zig        binary index format + loader
  knn.zig          nearest-neighbour search
  json.zig         payload parser
  fdpass.zig       fd-passing helpers
  lb.zig           load balancer
  server.zig       API worker
  preprocessor.zig build-time index builder
  bench.zig        offline accuracy harness
build.zig
Dockerfile
docker-compose.yml           local build
docker-compose.nginx.yml     nginx variant
submission/                  files for the submission branch
```

## Build & run

```sh
zig build test
docker compose up --build      # :9999
```

The amd64 image (for submission) is built with:

```sh
docker buildx build --platform linux/amd64 -t <registry>/<image>:latest --push .
```

## License

MIT.
