package io.gatewaysmashes.rhcl.api;

import java.util.Map;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;
import org.jboss.resteasy.reactive.RestStreamElementType;

import io.gatewaysmashes.rhcl.ai.AiTokenMetrics;
import io.gatewaysmashes.rhcl.ai.ChatCompletionContext;
import io.gatewaysmashes.rhcl.ai.OpenAiChatService;

import io.micrometer.core.instrument.MeterRegistry;
import io.smallrye.mutiny.Multi;
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
 * OpenAI-compatible chat completions on the app connectivity path
 * {@code /api/v1/chat/completions} (RHCL HTTPRoute {@code banking-api-connectivity}).
 */
@Path("/api/v1/chat/completions")
@Consumes(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class AiV1CompletionsResource {

    private static final Logger LOG = Logger.getLogger(AiV1CompletionsResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @Inject
    OpenAiChatService chatService;

    @Inject
    MeterRegistry meterRegistry;

    private static final String ROUTE = "/api/v1/chat/completions";

    @POST
    @Produces(MediaType.APPLICATION_JSON)
    public Response completion(Map<String, Object> request,
                               @HeaderParam("x-consumer-id") String consumer) {
        ChatCompletionContext ctx = chatService.prepare(request, consumer);
        if (ctx.stream()) {
            LOG.warnf("ai completion stream=true received but Accept is JSON; returning non-stream response consumer=%s",
                    ctx.consumerId());
        }
        AiTokenMetrics.record(meterRegistry, ROUTE, ctx.model(), ctx.consumerId(),
                ctx.promptTokens(), ctx.completionTokens());
        return jsonResponse(ctx);
    }

    @POST
    @Produces(MediaType.SERVER_SENT_EVENTS)
    @RestStreamElementType(MediaType.APPLICATION_JSON)
    public Multi<String> completionStream(Map<String, Object> request,
                                          @HeaderParam("x-consumer-id") String consumer) {
        ChatCompletionContext ctx = chatService.prepare(request, consumer);
        // Record at prepare-time so we still get a count if the client
        // disconnects mid-stream; the worst case is a slight over-count
        // for aborted streams, which beats losing the cost signal.
        AiTokenMetrics.record(meterRegistry, ROUTE, ctx.model(), ctx.consumerId(),
                ctx.promptTokens(), ctx.completionTokens());
        return chatService.completionStream(ctx);
    }

    private Response jsonResponse(ChatCompletionContext ctx) {
        return Response.ok(chatService.buildJsonResponse(ctx))
                .header("x-instance", instanceName)
                .header("x-consumer-id", ctx.consumerId())
                .header("x-context-tokens", String.valueOf(ctx.contextTokens()))
                .header("x-context-items", String.valueOf(ctx.contextItems()))
                .build();
    }
}
