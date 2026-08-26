FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /workspace
COPY pubspec.yaml pubspec.lock* ./
RUN flutter pub get
COPY . .
RUN flutter build web --release

FROM nginx:1.27-alpine
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /workspace/build/web /usr/share/nginx/html
EXPOSE 8080
