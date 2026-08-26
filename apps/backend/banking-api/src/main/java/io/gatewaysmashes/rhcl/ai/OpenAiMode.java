package io.gatewaysmashes.rhcl.ai;

/**
 * How the banking-api exposes OpenAI-compatible endpoints.
 * <ul>
 *   <li>{@code mock} — deterministic in-process responses (default for PoC)</li>
 *   <li>{@code disabled} — AI routes return HTTP 503</li>
 * </ul>
 */
public enum OpenAiMode {
    MOCK,
    DISABLED;

    public static OpenAiMode fromConfig(String raw) {
        if (raw == null || raw.isBlank()) {
            return MOCK;
        }
        return switch (raw.trim().toLowerCase()) {
            case "disabled", "off" -> DISABLED;
            default -> MOCK;
        };
    }
}
