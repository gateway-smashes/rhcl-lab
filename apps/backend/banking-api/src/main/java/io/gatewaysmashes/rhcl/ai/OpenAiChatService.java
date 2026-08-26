package io.gatewaysmashes.rhcl.ai;

import io.smallrye.mutiny.Multi;

import java.util.Map;

/**
 * OpenAI-compatible chat completions and model listing for the PoC mock provider.
 */
public interface OpenAiChatService {

    ChatCompletionContext prepare(Map<String, Object> request, String consumerHeader);

    Map<String, Object> buildJsonResponse(ChatCompletionContext ctx);

    Multi<String> completionStream(ChatCompletionContext ctx);

    Map<String, Object> listModels();
}
