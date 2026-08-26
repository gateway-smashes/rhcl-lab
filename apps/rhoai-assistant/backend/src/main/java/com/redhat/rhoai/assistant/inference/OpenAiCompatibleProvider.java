package com.redhat.rhoai.assistant.inference;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.subscription.MultiEmitter;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import com.redhat.rhoai.assistant.inference.MaasHttpClientFactory;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

@ApplicationScoped
public class OpenAiCompatibleProvider implements InferenceProvider {

    private static final Logger LOG = Logger.getLogger(OpenAiCompatibleProvider.class);

    @ConfigProperty(name = "rhoai.maas.api-key")
    String apiKey;

    @Inject
    ObjectMapper objectMapper;

    @Inject
    MaasAuthTokenProvider authTokenProvider;

    @Inject
    MaasHttpClientFactory httpClientFactory;

    private HttpClient httpClient;

    @jakarta.annotation.PostConstruct
    void init() {
        httpClient = httpClientFactory.create(Duration.ofSeconds(30));
    }

    @Override
    public boolean supports(ModelConfiguration model) {
        String provider = model.provider() != null ? model.provider().toLowerCase() : "";
        return provider.equals("rhoai")
                || provider.equals("openai")
                || provider.equals("litellm")
                || provider.equals("external");
    }

    @Override
    public Multi<InferenceEvent> stream(ModelConfiguration model, InferenceRequest request) {
        if (apiKey == null || apiKey.isBlank()) {
            try {
                authTokenProvider.bearerToken();
            } catch (Exception e) {
                return Multi.createFrom().failure(new IllegalStateException("MAAS_API_KEY is not configured"));
            }
        }

        return Multi.createFrom().emitter(emitter -> {
            Thread.startVirtualThread(() -> runInference(model, request, emitter));
        });
    }

    private void runInference(
            ModelConfiguration model,
            InferenceRequest request,
            MultiEmitter<? super InferenceEvent> emitter) {
        long startMs = System.currentTimeMillis();
        AtomicLong firstTokenMs = new AtomicLong(-1);

        try {
            String baseUrl = model.endpoint();
            if (baseUrl.endsWith("/")) {
                baseUrl = baseUrl.substring(0, baseUrl.length() - 1);
            }
            String url = baseUrl + "/chat/completions";

            Map<String, Object> body = new HashMap<>();
            body.put("model", request.modelId());
            body.put("messages", request.messages());
            body.put("stream", true);
            body.put("stream_options", Map.of("include_usage", true));

            HttpRequest httpRequest = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofMinutes(5))
                    .header("Authorization", "Bearer " + authTokenProvider.bearerToken())
                    .header("Content-Type", "application/json")
                    .header("Accept", "text/event-stream")
                    .POST(HttpRequest.BodyPublishers.ofString(objectMapper.writeValueAsString(body)))
                    .build();

            HttpResponse<String> response = httpClient.send(httpRequest, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                emitter.fail(new InferenceException(response.statusCode(), response.body()));
                return;
            }

            int inputTokens = 0;
            int outputTokens = 0;
            String effectiveModel = request.modelId();
            String responseBody = response.body();

            for (String line : responseBody.split("\n")) {
                line = line.trim();
                if (!line.startsWith("data:")) {
                    continue;
                }
                String data = line.substring(5).trim();
                if ("[DONE]".equals(data)) {
                    break;
                }
                JsonNode node = objectMapper.readTree(data);
                if (node.has("model")) {
                    effectiveModel = node.get("model").asText();
                }
                JsonNode choices = node.get("choices");
                if (choices != null && choices.isArray() && !choices.isEmpty()) {
                    JsonNode delta = choices.get(0).get("delta");
                    if (delta != null && delta.has("content")) {
                        String content = delta.get("content").asText("");
                        if (!content.isEmpty()) {
                            if (firstTokenMs.get() < 0) {
                                firstTokenMs.set(System.currentTimeMillis() - startMs);
                            }
                            emitter.emit(InferenceEvent.delta(request.requestId(), content));
                        }
                    }
                }
                JsonNode usage = node.get("usage");
                if (usage != null) {
                    inputTokens = usage.path("prompt_tokens").asInt(0);
                    outputTokens = usage.path("completion_tokens").asInt(0);
                }
            }

            long latency = System.currentTimeMillis() - startMs;
            long ttft = firstTokenMs.get() >= 0 ? firstTokenMs.get() : latency;
            emitter.emit(InferenceEvent.effectiveModel(request.requestId(), effectiveModel));
            emitter.emit(InferenceEvent.usage(request.requestId(), inputTokens, outputTokens, latency, ttft, 0.0));
            emitter.complete();
        } catch (Exception e) {
            LOG.errorf(e, "Inference error for model %s", model.id());
            emitter.fail(e);
        }
    }
}
