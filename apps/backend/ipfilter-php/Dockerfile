FROM registry.access.redhat.com/ubi9/php-82:latest

WORKDIR /opt/app-root/src
COPY src/ /opt/app-root/src/

EXPOSE 8080

USER 1001

CMD ["php", "-S", "0.0.0.0:8080", "-t", "/opt/app-root/src"]
