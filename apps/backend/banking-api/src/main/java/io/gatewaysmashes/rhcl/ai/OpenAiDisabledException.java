package io.gatewaysmashes.rhcl.ai;

/**
 * Raised when {@code app.openai.mode=disabled} and a client hits an AI route.
 */
public class OpenAiDisabledException extends RuntimeException {

    public OpenAiDisabledException() {
        super("OpenAI-compatible endpoints are disabled (app.openai.mode=disabled)");
    }
}
