package io.gatewaysmashes.rhcl.ai;

/**
 * Prepared state for one chat completion (JSON or SSE).
 */
public record ChatCompletionContext(
        String model,
        String consumerId,
        boolean stream,
        String prompt,
        String answer,
        int promptTokens,
        int completionTokens,
        int contextItems,
        int contextTokens) {
}
