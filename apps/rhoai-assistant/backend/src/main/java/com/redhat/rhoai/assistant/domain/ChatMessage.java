package com.redhat.rhoai.assistant.domain;

import java.time.Instant;
import java.util.UUID;

public record ChatMessage(
        String id,
        String conversationId,
        MessageRole role,
        String content,
        int sequence,
        Instant createdAt) {

    public enum MessageRole {
        USER, ASSISTANT, SYSTEM
    }

    public static ChatMessage user(String conversationId, int sequence, String content) {
        return new ChatMessage(
                UUID.randomUUID().toString(),
                conversationId,
                MessageRole.USER,
                content,
                sequence,
                Instant.now());
    }

    public static ChatMessage assistant(String conversationId, int sequence, String content) {
        return new ChatMessage(
                UUID.randomUUID().toString(),
                conversationId,
                MessageRole.ASSISTANT,
                content,
                sequence,
                Instant.now());
    }
}
