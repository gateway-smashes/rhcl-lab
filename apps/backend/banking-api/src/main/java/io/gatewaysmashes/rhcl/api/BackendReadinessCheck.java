package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.health.HealthCheck;
import org.eclipse.microprofile.health.HealthCheckResponse;
import org.eclipse.microprofile.health.Readiness;

/**
 * Readiness probe driven by {@link BackendModeHolder}. When the mode is set to
 * {@code down} via {@code POST /api/test/mode}, {@code /q/health/ready} returns
 * 503 — useful to drive RHCL/Kuadrant circuit breakers and outlier detection.
 */
@Readiness
@ApplicationScoped
public class BackendReadinessCheck implements HealthCheck {

    @Inject
    BackendModeHolder holder;

    @Override
    public HealthCheckResponse call() {
        return HealthCheckResponse.named("backend-mode")
                .status(holder.isReady())
                .withData("mode", holder.getMode())
                .withData("failRate", String.valueOf(holder.getFailRate()))
                .build();
    }
}
