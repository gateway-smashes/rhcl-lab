# syntax=docker/dockerfile:1.7

FROM maven:3.9.11-eclipse-temurin-25 AS build
WORKDIR /workspace

COPY pom.xml .
COPY src ./src

RUN mvn -DskipTests package

FROM eclipse-temurin:25-jre
WORKDIR /work/

RUN useradd --uid 1001 --create-home appuser

COPY --from=build /workspace/target/quarkus-app/lib/ /work/lib/
COPY --from=build /workspace/target/quarkus-app/*.jar /work/
COPY --from=build /workspace/target/quarkus-app/app/ /work/app/
COPY --from=build /workspace/target/quarkus-app/quarkus/ /work/quarkus/

ENV QUARKUS_HTTP_HOST=0.0.0.0
EXPOSE 8080 8443

USER 1001
ENTRYPOINT ["java","-jar","/work/quarkus-run.jar"]
