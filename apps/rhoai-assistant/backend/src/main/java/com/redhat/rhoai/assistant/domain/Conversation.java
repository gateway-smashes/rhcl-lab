package com.redhat.rhoai.assistant.domain;

import java.time.Instant;
import java.util.UUID;

public record Conversation(
        String id,
        String userId,
        String title,
        String requestedModel,
        String activeModel,
        String activeProvider,
        Instant createdAt,
        Instant updatedAt) {

    public static Conversation create(String userId, String title, String requestedModel) {
        Instant now = Instant.now();
        return new Conversation(
                UUID.randomUUID().toString(),
                userId,
                title != null && !title.isBlank() ? title : "New conversation",
                requestedModel != null ? requestedModel : "auto",
                null,
                null,
                now,
                now);
    }

    public Conversation withActiveModel(String model, String provider) {
        return new Conversation(id, userId, title, requestedModel, model, provider, createdAt, Instant.now());
    }

    public Conversation withRequestedModel(String model) {
        return new Conversation(id, userId, title, model, activeModel, activeProvider, createdAt, Instant.now());
    }

    public Conversation withTitle(String newTitle) {
        return new Conversation(id, userId, newTitle, requestedModel, activeModel, activeProvider, createdAt, Instant.now());
    }
}
