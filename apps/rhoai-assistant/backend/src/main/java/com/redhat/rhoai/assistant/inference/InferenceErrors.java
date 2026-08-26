package com.redhat.rhoai.assistant.inference;

import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class InferenceErrors {

    private static final Pattern HTTP_STATUS = Pattern.compile("HTTP (\\d{3})");

    private InferenceErrors() {}

    public static Map<String, Object> toErrorPayload(String requestId, Throwable error) {
        if (error instanceof InferenceException ex) {
            return Map.of(
                    "requestId", requestId,
                    "statusCode", ex.statusCode(),
                    "code", ex.errorCode(),
                    "message", ex.userMessage());
        }

        String raw = error.getMessage() != null && !error.getMessage().isBlank()
                ? error.getMessage()
                : "Inference failed";
        int statusCode = extractStatusCode(raw);
        String code = statusCode == 429
                ? "RATE_LIMITED"
                : statusCode == 503
                        ? "UPSTREAM_UNAVAILABLE"
                        : "INFERENCE_FAILED";
        String message = statusCode == 429
                ? "Rate limit reached (HTTP 429). Token quota exceeded for this model. "
                        + "Wait for the limit window to reset or choose another model."
                : raw;

        Map<String, Object> payload = new HashMap<>();
        payload.put("requestId", requestId);
        payload.put("code", code);
        payload.put("message", message);
        if (statusCode > 0) {
            payload.put("statusCode", statusCode);
        }
        return payload;
    }

    private static int extractStatusCode(String message) {
        Matcher matcher = HTTP_STATUS.matcher(message);
        if (matcher.find()) {
            return Integer.parseInt(matcher.group(1));
        }
        if (message.toLowerCase().contains("too many requests")) {
            return 429;
        }
        return 0;
    }
}
