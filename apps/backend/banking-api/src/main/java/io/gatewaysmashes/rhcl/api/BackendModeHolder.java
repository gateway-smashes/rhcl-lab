package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Mutable holder for PoC backend behavior modes. Used by {@link TestResource}
 * to drive failure / latency injection scenarios and by {@link BackendReadinessCheck}
 * so external probes (gateway circuit breakers, K8s readiness) react to mode changes.
 */
@ApplicationScoped
public class BackendModeHolder {

    public static final String MODE_HEALTHY = "healthy";
    public static final String MODE_DEGRADED = "degraded";
    public static final String MODE_DOWN = "down";

    private volatile String mode = MODE_HEALTHY;
    private volatile double failRate = 0.0d;

    public String getMode() {
        return mode;
    }

    public void setMode(String newMode) {
        if (newMode == null) {
            return;
        }
        switch (newMode) {
            case MODE_HEALTHY:
            case MODE_DEGRADED:
            case MODE_DOWN:
                this.mode = newMode;
                break;
            default:
                throw new IllegalArgumentException("Unsupported mode: " + newMode
                        + " (expected healthy|degraded|down)");
        }
    }

    public double getFailRate() {
        return failRate;
    }

    public void setFailRate(double newFailRate) {
        if (newFailRate < 0.0d || newFailRate > 1.0d) {
            throw new IllegalArgumentException("failRate must be within [0.0, 1.0]");
        }
        this.failRate = newFailRate;
    }

    public boolean isReady() {
        return !MODE_DOWN.equals(mode);
    }

    /**
     * Effective failure ratio combining explicit failRate with the implicit ratio
     * derived from {@link #mode} ({@code degraded} forces a baseline of 0.5).
     */
    public double effectiveFailRate() {
        double base = MODE_DEGRADED.equals(mode) ? 0.5d : 0.0d;
        return Math.max(base, failRate);
    }

    public Map<String, Object> snapshot() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("mode", mode);
        data.put("failRate", failRate);
        data.put("effectiveFailRate", effectiveFailRate());
        data.put("ready", isReady());
        return data;
    }
}
