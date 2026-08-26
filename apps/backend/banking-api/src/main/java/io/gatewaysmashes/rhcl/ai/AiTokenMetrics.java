package io.gatewaysmashes.rhcl.ai;

import io.micrometer.core.instrument.MeterRegistry;

/**
 * Emits the {@code bank_ai_tokens_total} Prometheus counter — req018
 * (Monitoração de Custo) reads this to attribute token spend to consumers
 * and routes.
 *
 * <p>One counter, two label values: {@code kind=prompt} and
 * {@code kind=completion}. Total tokens = sum over both kinds. We keep
 * prompt and completion as separate series instead of just emitting
 * {@code total_tokens} so cost models with asymmetric pricing (token in
 * vs token out — the OpenAI billing model) can be expressed without
 * adding a second counter later.</p>
 *
 * <p>Labels:</p>
 * <ul>
 *   <li>{@code kind}        — "prompt" or "completion"</li>
 *   <li>{@code consumer_id} — the {@code x-consumer-id} the gateway
 *       injects post-auth (or {@code anonymous} when the request never
 *       passed Authorino)</li>
 *   <li>{@code model}       — the OpenAI {@code model} parameter</li>
 *   <li>{@code route}       — the OpenAPI path template (e.g.
 *       {@code /api/v1/chat/completions}). We intentionally pass the
 *       template, not the parameterised URL, to keep cardinality
 *       bounded — IDs in the path would explode the time series.</li>
 * </ul>
 */
public final class AiTokenMetrics {

    public static final String COUNTER_NAME = "bank_ai_tokens_total";
    private static final String ANON = "anonymous";

    private AiTokenMetrics() { }

    /**
     * Record one AI completion against the counter.
     *
     * <p>Both increments are guarded by {@code > 0} so a 0-token call
     * (embedding with empty input, refused request) doesn't pollute the
     * series with zero-valued samples.</p>
     */
    public static void record(MeterRegistry registry, String route, String model,
                              String consumerId, int promptTokens, int completionTokens) {
        if (registry == null) return;
        // The Istio Telemetry CR rewrites missing header values to the
        // literal string "<nil>" when materialising the
        // request_headers_x_consumer_id label. Mirror the convention
        // here so the cost dashboard's anonymous bucket matches between
        // istio_requests_total and bank_ai_tokens_total without extra
        // label_replace gymnastics in PromQL.
        String safeConsumer = (consumerId == null || consumerId.isBlank() || "<nil>".equals(consumerId))
                ? ANON : consumerId;
        String safeModel = (model == null || model.isBlank()) ? "unknown" : model;
        String safeRoute = (route == null || route.isBlank()) ? "unknown" : route;

        if (promptTokens > 0) {
            registry.counter(COUNTER_NAME,
                    "kind", "prompt",
                    "consumer_id", safeConsumer,
                    "model", safeModel,
                    "route", safeRoute).increment(promptTokens);
        }
        if (completionTokens > 0) {
            registry.counter(COUNTER_NAME,
                    "kind", "completion",
                    "consumer_id", safeConsumer,
                    "model", safeModel,
                    "route", safeRoute).increment(completionTokens);
        }
    }
}
