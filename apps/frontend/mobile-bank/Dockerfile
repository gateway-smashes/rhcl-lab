# syntax=docker/dockerfile:1.7

FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /workspace

# Defaults intencionalmente vazios para builds genéricos (Quay sem build-args).
# Em runtime a app puxa o valor real do localStorage (configurado pelo usuário
# no painel de endpoints da própria UI). Pra build com URL baked, sobrescreva
# os ARGs via --build-arg na build local OU pela BuildConfig do OCP que injeta
# APPS_FRONTEND_RHCL_GATEWAY_URL.
ARG PRIMARY_BACKEND_URL=http://localhost:8080/api/v1/accounts/summary
ARG SECONDARY_BACKEND_URL=http://localhost:8081/api/v2/accounts/summary
ARG RHCL_GATEWAY_URL=https://banking-api-connectivity.apps.cluster-r46jf.r46jf.sandbox3219.opentlc.com
ARG DEFAULT_FLOW_MODE=primary_only
ARG MCP_GATEWAY_URL=
ARG RHCL_API_KEY=alice-gold-secret

COPY pubspec.yaml pubspec.lock* ./
RUN flutter pub get

COPY . .
RUN flutter build web --release \
    --pwa-strategy=none \
    --dart-define=PRIMARY_BACKEND_URL=${PRIMARY_BACKEND_URL} \
    --dart-define=SECONDARY_BACKEND_URL=${SECONDARY_BACKEND_URL} \
    --dart-define=RHCL_GATEWAY_URL=${RHCL_GATEWAY_URL} \
    --dart-define=MCP_GATEWAY_URL=${MCP_GATEWAY_URL} \
    --dart-define=DEFAULT_FLOW_MODE=${DEFAULT_FLOW_MODE} \
    --dart-define=RHCL_API_KEY=${RHCL_API_KEY}
# --pwa-strategy=none skips the flutter_service_worker.js entirely.
# The PoC image is redeployed several times a day (Comprovantes tab,
# WS fixes, PoC console iterations) and the default service worker
# aggressively caches JS assets — Firefox in particular held onto old
# main.dart.js builds across normal reloads, forcing operators to
# clear site data by hand. For a demo app that ships new versions
# frequently there's no upside to the offline-first cache.

FROM nginx:1.27-alpine

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /workspace/build/web /usr/share/nginx/html

EXPOSE 8080
ENTRYPOINT ["nginx","-g","daemon off;"]
