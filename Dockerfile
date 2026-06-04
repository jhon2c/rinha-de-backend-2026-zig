# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM alpine:3.20 AS builder
ARG TARGETARCH
RUN apk add --no-cache curl xz
RUN BARCH=$(uname -m) && \
    curl -fsSL "https://ziglang.org/download/0.16.0/zig-${BARCH}-linux-0.16.0.tar.xz" -o /zig.tar.xz && \
    mkdir -p /opt/zig && tar -xJf /zig.tar.xz -C /opt/zig --strip-components=1 && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig ./
COPY src ./src
COPY resources ./resources

RUN zig build preprocessor -Doptimize=ReleaseFast && \
    gunzip -c resources/references.json.gz > /tmp/references.json && \
    ./zig-out/bin/preprocessor /tmp/references.json /app/index.bin 2560 200000 15 && \
    rm /tmp/references.json

RUN case "$TARGETARCH" in \
      amd64) ZTARGET="x86_64-linux-musl"; ZCPU="haswell" ;; \
      arm64) ZTARGET="aarch64-linux-musl"; ZCPU="baseline" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    zig build server -Doptimize=ReleaseFast -Dtarget="$ZTARGET" -Dcpu="$ZCPU" && \
    cp zig-out/bin/server /app/server && cp zig-out/bin/lb /app/lb

FROM scratch
COPY --from=builder /app/server /server
COPY --from=builder /app/lb /lb
COPY --from=builder /app/index.bin /index.bin
EXPOSE 9999
