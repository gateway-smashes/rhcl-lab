package com.redhat.rhoai.assistant.inference;

import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import io.smallrye.mutiny.Multi;

import java.util.List;
import java.util.Map;

public interface InferenceProvider {

    boolean supports(ModelConfiguration model);

    Multi<InferenceEvent> stream(ModelConfiguration model, InferenceRequest request);

    record InferenceRequest(
            String requestId,
            String modelId,
            List<Map<String, String>> messages,
            boolean stream) {}

    record InferenceEvent(
            InferenceEventType type,
            Map<String, Object> data) {

        public static InferenceEvent delta(String requestId, String content) {
            return new InferenceEvent(InferenceEventType.CONTENT_DELTA, Map.of(
                    "requestId", requestId,
                    "content", content));
        }

        public static InferenceEvent usage(
                String requestId,
                int inputTokens,
                int outputTokens,
                long latencyMs,
                long ttftMs,
                double estimatedCost) {
            return new InferenceEvent(InferenceEventType.USAGE, Map.of(
                    "requestId", requestId,
                    "inputTokens", inputTokens,
                    "outputTokens", outputTokens,
                    "totalTokens", inputTokens + outputTokens,
                    "latencyMs", latencyMs,
                    "timeToFirstTokenMs", ttftMs,
                    "estimatedCost", estimatedCost,
                    "currency", "USD"));
        }

        public static InferenceEvent effectiveModel(String requestId, String modelId) {
            return new InferenceEvent(InferenceEventType.EFFECTIVE_MODEL, Map.of(
                    "requestId", requestId,
                    "effectiveModel", modelId));
        }
    }

    enum InferenceEventType {
        CONTENT_DELTA,
        USAGE,
        EFFECTIVE_MODEL,
        ERROR
    }
}
