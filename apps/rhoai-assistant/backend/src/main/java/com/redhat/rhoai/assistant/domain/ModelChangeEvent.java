package com.redhat.rhoai.assistant.domain;

import java.time.Instant;
import java.util.UUID;

public record ModelChangeEvent(
        String id,
        String executionId,
        String conversationId,
        String fromModel,
        String toModel,
        String fromProvider,
        String toProvider,
        ModelChangeReason reason,
        Instant createdAt) {

    public static ModelChangeEvent create(
            String executionId,
            String conversationId,
            String fromModel,
            String toModel,
            String fromProvider,
            String toProvider,
            ModelChangeReason reason) {
        return new ModelChangeEvent(
                UUID.randomUUID().toString(),
                executionId,
                conversationId,
                fromModel,
                toModel,
                fromProvider,
                toProvider,
                reason,
                Instant.now());
    }
}
