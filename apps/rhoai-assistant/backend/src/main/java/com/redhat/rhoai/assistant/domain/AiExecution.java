package com.redhat.rhoai.assistant.domain;

import java.time.Instant;
import java.util.UUID;

public record AiExecution(
        String id,
        String conversationId,
        String messageId,
        String requestId,
        String requestedModel,
        String selectedModel,
        String effectiveModel,
        String provider,
        String runtime,
        String selectionReason,
        boolean modelVerified,
        int inputTokens,
        int outputTokens,
        int totalTokens,
        double estimatedCost,
        long latencyMs,
        long timeToFirstTokenMs,
        ExecutionStatus status,
        Instant startedAt,
        Instant completedAt) {

    public enum ExecutionStatus {
        RUNNING, COMPLETED, FAILED, CANCELLED
    }

    public static AiExecution start(
            String conversationId,
            String messageId,
            String requestId,
            String requestedModel,
            String selectedModel,
            String provider,
            String runtime,
            String selectionReason) {
        return new AiExecution(
                UUID.randomUUID().toString(),
                conversationId,
                messageId,
                requestId,
                requestedModel,
                selectedModel,
                selectedModel,
                provider,
                runtime,
                selectionReason,
                false,
                0, 0, 0, 0.0,
                0, 0,
                ExecutionStatus.RUNNING,
                Instant.now(),
                null);
    }

    public AiExecution withEffectiveModel(String effective, boolean verified) {
        return new AiExecution(
                id, conversationId, messageId, requestId,
                requestedModel, selectedModel, effective,
                provider, runtime, selectionReason, verified,
                inputTokens, outputTokens, totalTokens, estimatedCost,
                latencyMs, timeToFirstTokenMs, status, startedAt, completedAt);
    }

    public AiExecution withUsage(int input, int output, double cost, long latency, long ttft) {
        int total = input + output;
        return new AiExecution(
                id, conversationId, messageId, requestId,
                requestedModel, selectedModel, effectiveModel,
                provider, runtime, selectionReason, modelVerified,
                input, output, total, cost,
                latency, ttft, status, startedAt, completedAt);
    }

    public AiExecution completed() {
        return new AiExecution(
                id, conversationId, messageId, requestId,
                requestedModel, selectedModel, effectiveModel,
                provider, runtime, selectionReason, modelVerified,
                inputTokens, outputTokens, totalTokens, estimatedCost,
                latencyMs, timeToFirstTokenMs,
                ExecutionStatus.COMPLETED, startedAt, Instant.now());
    }

    public AiExecution failed() {
        return new AiExecution(
                id, conversationId, messageId, requestId,
                requestedModel, selectedModel, effectiveModel,
                provider, runtime, selectionReason, modelVerified,
                inputTokens, outputTokens, totalTokens, estimatedCost,
                latencyMs, timeToFirstTokenMs,
                ExecutionStatus.FAILED, startedAt, Instant.now());
    }

    public AiExecution cancelled() {
        return new AiExecution(
                id, conversationId, messageId, requestId,
                requestedModel, selectedModel, effectiveModel,
                provider, runtime, selectionReason, modelVerified,
                inputTokens, outputTokens, totalTokens, estimatedCost,
                latencyMs, timeToFirstTokenMs,
                ExecutionStatus.CANCELLED, startedAt, Instant.now());
    }
}
