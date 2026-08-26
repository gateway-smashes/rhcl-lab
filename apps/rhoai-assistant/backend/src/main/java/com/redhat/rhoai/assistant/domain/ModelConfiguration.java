package com.redhat.rhoai.assistant.domain;

import java.time.Instant;

public record ModelConfiguration(
        String id,
        String displayName,
        String provider,
        String runtime,
        ModelOrigin origin,
        String endpoint,
        String externalModelResource,
        ModelStatus status,
        int priority,
        int contextWindow,
        boolean streamingSupported,
        boolean toolsSupported,
        boolean visionSupported,
        String fallbackModel,
        boolean enabled,
        double estimatedInputCost,
        double estimatedOutputCost,
        Instant lastHealthCheck) {

    public enum ModelOrigin {
        LOCAL, EXTERNAL
    }

    public enum ModelStatus {
        AVAILABLE, UNAVAILABLE, DEGRADED, UNKNOWN
    }

    public ModelConfiguration withStatus(ModelStatus newStatus, Instant checkedAt) {
        return new ModelConfiguration(
                id, displayName, provider, runtime, origin, endpoint, externalModelResource, newStatus,
                priority, contextWindow, streamingSupported, toolsSupported, visionSupported,
                fallbackModel, enabled, estimatedInputCost, estimatedOutputCost, checkedAt);
    }

    public ModelConfiguration withEndpoint(String newEndpoint) {
        return new ModelConfiguration(
                id, displayName, provider, runtime, origin, newEndpoint, externalModelResource, status,
                priority, contextWindow, streamingSupported, toolsSupported, visionSupported,
                fallbackModel, enabled, estimatedInputCost, estimatedOutputCost, lastHealthCheck);
    }
}
