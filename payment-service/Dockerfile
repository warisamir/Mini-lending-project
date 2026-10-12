# syntax=docker/dockerfile:1

# ---- build -------------------------------------------------------------
# Tests are not run here: they need a Docker daemon (Testcontainers). Run them in CI or locally with ./mvnw test.
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace

# Resolve dependencies first so code-only changes reuse this layer
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q package -DskipTests

# ---- runtime -----------------------------------------------------------
FROM eclipse-temurin:17-jre

RUN groupadd --system app && useradd --system --gid app --no-create-home app

WORKDIR /app
COPY --from=build /workspace/target/payment-service-0.0.1-SNAPSHOT.jar app.jar

# Pin the JVM to UTC (the database stores TIMESTAMPTZ; see PaymentServiceApplication)
ENV JAVA_TOOL_OPTIONS="-Duser.timezone=UTC -XX:MaxRAMPercentage=75.0"

USER app
EXPOSE 8081

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
