package io.gatewaysmashes.rhcl.ai;

import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@ApplicationScoped
public class MockOpenAiChatService implements OpenAiChatService {

    private static final Logger LOG = Logger.getLogger(MockOpenAiChatService.class);
    private static final String DEFAULT_CONSUMER = "anonymous";

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @ConfigProperty(name = "app.openai.mode", defaultValue = "mock")
    String openAiMode;

    @ConfigProperty(name = "app.openai.default-model", defaultValue = "banking-mock-gpt")
    String defaultModel;

    @ConfigProperty(name = "app.openai.stream-chunk-delay-ms", defaultValue = "40")
    long streamChunkDelayMs;

    @Override
    public ChatCompletionContext prepare(Map<String, Object> request, String consumerHeader) {
        assertEnabled();
        String model = request != null && request.get("model") != null
                ? String.valueOf(request.get("model")) : defaultModel;
        boolean stream = request != null && Boolean.TRUE.equals(request.get("stream"));
        String consumerId = (consumerHeader == null || consumerHeader.isBlank())
                ? DEFAULT_CONSUMER : consumerHeader;

        String prompt = extractPrompt(request);
        ContextSummary contextSummary = extractContext(request);
        String answer = mockAnswer(prompt, contextSummary);
        UsageOverride usageOverride = extractMockUsage(request);
        int promptTokens = usageOverride.promptTokens >= 0
                ? usageOverride.promptTokens
                : estimateTokens(prompt);
        int completionTokens = usageOverride.completionTokens >= 0
                ? usageOverride.completionTokens
                : estimateTokens(answer);

        LOG.infof("ai completion model=%s consumer=%s instance=%s stream=%s promptChars=%d promptTokens=%d completionTokens=%d contextItems=%d contextTokens=%d prompt=%s",
                model, consumerId, instanceName, stream, prompt.length(),
                promptTokens, completionTokens, contextSummary.items, contextSummary.tokens,
                truncate(prompt, 500));

        return new ChatCompletionContext(model, consumerId, stream, prompt, answer,
                promptTokens, completionTokens, contextSummary.items, contextSummary.tokens);
    }

    @Override
    public Map<String, Object> buildJsonResponse(ChatCompletionContext ctx) {
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("role", "assistant");
        message.put("content", ctx.answer());

        Map<String, Object> choice = new LinkedHashMap<>();
        choice.put("index", 0);
        choice.put("message", message);
        choice.put("finish_reason", "stop");

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("id", "chatcmpl-" + UUID.randomUUID());
        response.put("object", "chat.completion");
        response.put("created", Instant.now().getEpochSecond());
        response.put("model", ctx.model());
        response.put("instance", instanceName);
        response.put("consumer", ctx.consumerId());
        response.put("choices", List.of(choice));
        response.put("usage", usage(ctx));
        Map<String, Object> contextInfo = new LinkedHashMap<>();
        contextInfo.put("items", ctx.contextItems());
        contextInfo.put("tokens", ctx.contextTokens());
        response.put("context", contextInfo);
        return response;
    }

    @Override
    public Multi<String> completionStream(ChatCompletionContext ctx) {
        assertEnabled();
        List<String> chunks = chunkAnswer(ctx.answer());
        long now = Instant.now().getEpochSecond();
        String id = "chatcmpl-" + UUID.randomUUID();
        long delayMs = Math.max(0, streamChunkDelayMs);

        Multi<String> deltas = Multi.createFrom().iterable(chunks)
                .onItem().transform(piece -> sseChunk(id, ctx.model(), now, streamChoice(piece)))
                .onItem().call(item -> io.smallrye.mutiny.Uni.createFrom().voidItem()
                        .onItem().delayIt().by(Duration.ofMillis(delayMs)));

        Multi<String> finalChunk = Multi.createFrom().item(() -> sseChunk(id, ctx.model(), now, Map.of(
                "index", 0,
                "delta", Map.of(),
                "finish_reason", "stop"
        ), usage(ctx)));

        Multi<String> done = Multi.createFrom().item("[DONE]");

        return Multi.createBy().concatenating().streams(deltas, finalChunk, done);
    }

    @Override
    public Map<String, Object> listModels() {
        assertEnabled();
        Map<String, Object> model = new LinkedHashMap<>();
        model.put("id", defaultModel);
        model.put("object", "model");
        model.put("created", Instant.now().getEpochSecond());
        model.put("owned_by", "rhcl-poc");

        Map<String, Object> list = new LinkedHashMap<>();
        list.put("object", "list");
        list.put("data", List.of(model));
        return list;
    }

    private void assertEnabled() {
        if (OpenAiMode.fromConfig(openAiMode) == OpenAiMode.DISABLED) {
            throw new OpenAiDisabledException();
        }
    }

    private Map<String, Object> usage(ChatCompletionContext ctx) {
        Map<String, Object> usage = new LinkedHashMap<>();
        usage.put("prompt_tokens", ctx.promptTokens());
        usage.put("completion_tokens", ctx.completionTokens());
        usage.put("total_tokens", ctx.promptTokens() + ctx.completionTokens());
        return usage;
    }

    @SuppressWarnings("unchecked")
    private String extractPrompt(Map<String, Object> request) {
        if (request == null) {
            return "";
        }
        Object messages = request.get("messages");
        if (!(messages instanceof List<?>)) {
            Object input = request.get("input");
            return input == null ? "" : String.valueOf(input);
        }
        StringBuilder sb = new StringBuilder();
        for (Object item : (List<?>) messages) {
            if (item instanceof Map<?, ?> msg) {
                Object content = msg.get("content");
                if (content != null) {
                    sb.append(content).append('\n');
                }
            }
        }
        return sb.toString().trim();
    }

    private String mockAnswer(String prompt, ContextSummary context) {
        if (prompt.isEmpty()) {
            return "Mock response from " + instanceName + ": no prompt was provided.";
        }
        String shortPrompt = prompt.length() > 120 ? prompt.substring(0, 120) + "…" : prompt;
        String contextNote = context.items > 0
                ? " Used " + context.items + " RAG context chunk(s) totalling ~" + context.tokens + " tokens."
                : "";
        return "Mock response from " + instanceName + ". You asked: \"" + shortPrompt
                + "\". This is deterministic content used to validate gateway policies." + contextNote;
    }

    @SuppressWarnings("unchecked")
    private ContextSummary extractContext(Map<String, Object> request) {
        if (request == null) {
            return new ContextSummary(0, 0);
        }
        Object raw = request.get("context");
        if (!(raw instanceof List<?> list) || list.isEmpty()) {
            return new ContextSummary(0, 0);
        }
        int tokens = 0;
        for (Object item : list) {
            String text;
            if (item instanceof Map<?, ?> map && map.get("text") != null) {
                text = String.valueOf(map.get("text"));
            } else {
                text = String.valueOf(item);
            }
            tokens += estimateTokens(text);
        }
        return new ContextSummary(list.size(), tokens);
    }

    @SuppressWarnings("unchecked")
    private UsageOverride extractMockUsage(Map<String, Object> request) {
        if (request == null) {
            return new UsageOverride(-1, -1);
        }
        Object raw = request.get("mock_usage");
        if (!(raw instanceof Map<?, ?>)) {
            raw = request.get("mockUsage");
        }
        if (!(raw instanceof Map<?, ?> map)) {
            return new UsageOverride(-1, -1);
        }
        return new UsageOverride(
                tokenOverride(map.get("prompt_tokens"), map.get("promptTokens")),
                tokenOverride(map.get("completion_tokens"), map.get("completionTokens")));
    }

    private int tokenOverride(Object snakeCase, Object camelCase) {
        Object value = snakeCase != null ? snakeCase : camelCase;
        if (value == null) {
            return -1;
        }
        if (value instanceof Number number) {
            return Math.max(0, number.intValue());
        }
        try {
            return Math.max(0, Integer.parseInt(String.valueOf(value)));
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    private List<String> chunkAnswer(String answer) {
        List<String> result = new ArrayList<>();
        int chunkSize = 16;
        for (int i = 0; i < answer.length(); i += chunkSize) {
            result.add(answer.substring(i, Math.min(answer.length(), i + chunkSize)));
        }
        if (result.isEmpty()) {
            result.add("");
        }
        return result;
    }

    private String sseChunk(String id, String model, long created, Map<String, Object> choice) {
        return sseChunk(id, model, created, choice, null);
    }

    private String sseChunk(String id, String model, long created, Map<String, Object> choice,
                            Map<String, Object> usage) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("id", id);
        payload.put("object", "chat.completion.chunk");
        payload.put("created", created);
        payload.put("model", model);
        payload.put("instance", instanceName);
        payload.put("choices", List.of(choice));
        if (usage != null) {
            payload.put("usage", usage);
        }
        return io.vertx.core.json.Json.encode(payload);
    }

    private Map<String, Object> streamChoice(String content) {
        Map<String, Object> delta = new LinkedHashMap<>();
        delta.put("content", content);

        Map<String, Object> choice = new LinkedHashMap<>();
        choice.put("index", 0);
        choice.put("delta", delta);
        choice.put("finish_reason", null);
        return choice;
    }

    private int estimateTokens(String text) {
        if (text == null || text.isEmpty()) {
            return 0;
        }
        return Math.max(1, (int) Math.ceil(text.length() / 4.0));
    }

    private String truncate(String value, int max) {
        if (value == null) {
            return "";
        }
        return value.length() <= max ? value : value.substring(0, max) + "…";
    }

    private record ContextSummary(int items, int tokens) { }

    private record UsageOverride(int promptTokens, int completionTokens) { }
}
