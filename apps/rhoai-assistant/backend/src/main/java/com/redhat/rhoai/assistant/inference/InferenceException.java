package com.redhat.rhoai.assistant.inference;

public class InferenceException extends RuntimeException {

    private final int statusCode;
    private final String responseBody;

    public InferenceException(int statusCode, String responseBody) {
        super(buildMessage(statusCode, responseBody));
        this.statusCode = statusCode;
        this.responseBody = responseBody;
    }

    public int statusCode() {
        return statusCode;
    }

    public String responseBody() {
        return responseBody;
    }

    public String errorCode() {
        return switch (statusCode) {
            case 429 -> "RATE_LIMITED";
            case 503 -> "UPSTREAM_UNAVAILABLE";
            case 401 -> "UNAUTHORIZED";
            case 403 -> "FORBIDDEN";
            default -> "INFERENCE_FAILED";
        };
    }

    public String userMessage() {
        return switch (statusCode) {
            case 429 -> "Rate limit reached (HTTP 429). Token quota exceeded for this model. "
                    + "Wait for the limit window to reset or choose another model.";
            case 503 -> "Model upstream temporarily unavailable (HTTP 503). Try again later.";
            case 401 -> "Authentication failed (HTTP 401). Check the MaaS API key.";
            case 403 -> "Access denied (HTTP 403). This identity or API key is not allowed for this model.";
            default -> getMessage();
        };
    }

    public static boolean isRateLimited(Throwable error) {
        if (error instanceof InferenceException ex) {
            return ex.statusCode() == 429;
        }
        String msg = error.getMessage();
        if (msg == null) {
            return false;
        }
        String lower = msg.toLowerCase();
        return msg.contains("HTTP 429") || lower.contains("too many requests");
    }

    private static String buildMessage(int statusCode, String responseBody) {
        String body = responseBody != null ? responseBody.trim() : "";
        if (body.isBlank()) {
            return "Inference failed: HTTP " + statusCode;
        }
        if (body.length() > 200) {
            body = body.substring(0, 200) + "…";
        }
        return "Inference failed: HTTP " + statusCode + " " + body;
    }
}
