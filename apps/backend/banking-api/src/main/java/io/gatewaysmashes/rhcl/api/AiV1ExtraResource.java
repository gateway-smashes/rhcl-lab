package io.gatewaysmashes.rhcl.api;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import io.gatewaysmashes.rhcl.ai.AiTokenMetrics;
import io.gatewaysmashes.rhcl.ai.OpenAiDisabledException;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Mock implementations of additional OpenAI-compatible endpoints:
 * <ul>
 *   <li>{@code POST /api/v1/completions}  — legacy text completions</li>
 *   <li>{@code POST /api/v1/embeddings}   — embedding vectors</li>
 *   <li>{@code POST /api/v1/responses}    — newer Responses API</li>
 * </ul>
 *
 * <p>Each endpoint is exposed by its own nested resource class with a
 * <b>fully-qualified</b> {@code @Path} on the class. We intentionally avoid a
 * shared class-level {@code @Path("/api/v1")} because Quarkus REST routes by
 * the most specific resource prefix; a sibling resource (e.g.
 * {@link BankingResource} {@code @Path("/api")}) would otherwise lose all
 * {@code /api/v1/*} sub-paths registered on a different class.</p>
 */
public final class AiV1ExtraResource {

    private AiV1ExtraResource() { }

    private static String resolveModel(Map<String, Object> request, String fallback) {
        return request != null && request.get("model") != null
                ? String.valueOf(request.get("model")) : fallback;
    }

    private static void assertEnabled(String openAiMode) {
        if ("disabled".equalsIgnoreCase(openAiMode) || "off".equalsIgnoreCase(openAiMode)) {
            throw new OpenAiDisabledException();
        }
    }

    // -------------------------------------------------------------------------
    // POST /api/v1/completions  (legacy text completions)
    // -------------------------------------------------------------------------

    @Path("/api/v1/completions")
    @ApplicationScoped
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public static class CompletionsResource {

        @ConfigProperty(name = "app.instance-name")
        String instanceName;

        @ConfigProperty(name = "app.openai.mode", defaultValue = "mock")
        String openAiMode;

        @ConfigProperty(name = "app.openai.default-model", defaultValue = "banking-mock-gpt")
        String defaultModel;

        @Inject
        MeterRegistry meterRegistry;

        @POST
        public Response completions(Map<String, Object> request,
                                    @HeaderParam("x-consumer-id") String consumer) {
            assertEnabled(openAiMode);
            String model = resolveModel(request, defaultModel);
            String prompt = request != null && request.get("prompt") != null
                    ? String.valueOf(request.get("prompt")) : "";
            String text = "Mock response for: " + (prompt.isBlank() ? "(empty prompt)" : prompt);
            int promptTokens = Math.max(1, prompt.length() / 4);
            int completionTokens = Math.max(1, text.length() / 4);
            AiTokenMetrics.record(meterRegistry, "/api/v1/completions", model, consumer,
                    promptTokens, completionTokens);

            Map<String, Object> choice = new LinkedHashMap<>();
            choice.put("text", text);
            choice.put("index", 0);
            choice.put("logprobs", null);
            choice.put("finish_reason", "stop");

            Map<String, Object> usage = new LinkedHashMap<>();
            usage.put("prompt_tokens", promptTokens);
            usage.put("completion_tokens", completionTokens);
            usage.put("total_tokens", promptTokens + completionTokens);

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("id", "cmpl-" + UUID.randomUUID().toString().replace("-", "").substring(0, 24));
            body.put("object", "text_completion");
            body.put("created", Instant.now().getEpochSecond());
            body.put("model", model);
            body.put("choices", List.of(choice));
            body.put("usage", usage);

            return Response.ok(body)
                    .header("x-instance", instanceName)
                    .header("x-consumer-id", consumer != null ? consumer : "anonymous")
                    .build();
        }
    }

    // -------------------------------------------------------------------------
    // POST /api/v1/embeddings
    // -------------------------------------------------------------------------

    @Path("/api/v1/embeddings")
    @ApplicationScoped
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public static class EmbeddingsResource {

        @ConfigProperty(name = "app.instance-name")
        String instanceName;

        @ConfigProperty(name = "app.openai.mode", defaultValue = "mock")
        String openAiMode;

        @Inject
        MeterRegistry meterRegistry;

        @POST
        public Response embeddings(Map<String, Object> request,
                                   @HeaderParam("x-consumer-id") String consumer) {
            assertEnabled(openAiMode);
            String model = request != null && request.get("model") != null
                    ? String.valueOf(request.get("model")) : "text-embedding-mock";

            Object inputRaw = request != null ? request.get("input") : null;
            List<String> inputs = new ArrayList<>();
            if (inputRaw instanceof List<?> list) {
                for (Object item : list) inputs.add(String.valueOf(item));
            } else if (inputRaw != null) {
                inputs.add(String.valueOf(inputRaw));
            } else {
                inputs.add("");
            }

            List<Map<String, Object>> data = new ArrayList<>();
            for (int i = 0; i < inputs.size(); i++) {
                int dim = 8;
                List<Double> vector = new ArrayList<>(dim);
                String text = inputs.get(i);
                for (int d = 0; d < dim; d++) {
                    vector.add(Math.sin((text.hashCode() + d) * 0.1));
                }
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("object", "embedding");
                item.put("index", i);
                item.put("embedding", vector);
                data.add(item);
            }

            int promptTokens = inputs.stream().mapToInt(s -> Math.max(1, s.length() / 4)).sum();
            // Embeddings have no "completion" — count tokens as prompt only.
            AiTokenMetrics.record(meterRegistry, "/api/v1/embeddings", model, consumer,
                    promptTokens, 0);

            Map<String, Object> usage = new LinkedHashMap<>();
            usage.put("prompt_tokens", promptTokens);
            usage.put("total_tokens", promptTokens);

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("object", "list");
            body.put("data", data);
            body.put("model", model);
            body.put("usage", usage);

            return Response.ok(body)
                    .header("x-instance", instanceName)
                    .header("x-consumer-id", consumer != null ? consumer : "anonymous")
                    .build();
        }
    }

    // -------------------------------------------------------------------------
    // POST /api/v1/responses  (OpenAI Responses API)
    // -------------------------------------------------------------------------

    @Path("/api/v1/responses")
    @ApplicationScoped
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public static class ResponsesResource {

        @ConfigProperty(name = "app.instance-name")
        String instanceName;

        @ConfigProperty(name = "app.openai.mode", defaultValue = "mock")
        String openAiMode;

        @ConfigProperty(name = "app.openai.default-model", defaultValue = "banking-mock-gpt")
        String defaultModel;

        @Inject
        MeterRegistry meterRegistry;

        @POST
        public Response responses(Map<String, Object> request,
                                  @HeaderParam("x-consumer-id") String consumer) {
            assertEnabled(openAiMode);
            String model = resolveModel(request, defaultModel);
            Object inputRaw = request != null ? request.get("input") : null;
            String input = inputRaw != null ? String.valueOf(inputRaw) : "";
            String outputText = "Mock response for: " + (input.isBlank() ? "(empty input)" : input);

            Map<String, Object> outputItem = new LinkedHashMap<>();
            outputItem.put("type", "message");
            outputItem.put("id", "msg_" + UUID.randomUUID().toString().replace("-", "").substring(0, 20));
            outputItem.put("role", "assistant");
            outputItem.put("content", List.of(Map.of("type", "output_text", "text", outputText)));
            outputItem.put("status", "completed");

            int inputTokens = Math.max(1, input.length() / 4);
            int outputTokens = Math.max(1, outputText.length() / 4);
            // The Responses API names them "input"/"output" but the
            // billing semantics map 1:1 onto prompt/completion.
            AiTokenMetrics.record(meterRegistry, "/api/v1/responses", model, consumer,
                    inputTokens, outputTokens);

            Map<String, Object> usage = new LinkedHashMap<>();
            usage.put("input_tokens", inputTokens);
            usage.put("output_tokens", outputTokens);
            usage.put("total_tokens", inputTokens + outputTokens);

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("id", "resp_" + UUID.randomUUID().toString().replace("-", "").substring(0, 20));
            body.put("object", "response");
            body.put("created_at", Instant.now().getEpochSecond());
            body.put("model", model);
            body.put("status", "completed");
            body.put("output", List.of(outputItem));
            body.put("usage", usage);

            return Response.ok(body)
                    .header("x-instance", instanceName)
                    .header("x-consumer-id", consumer != null ? consumer : "anonymous")
                    .build();
        }
    }
}
