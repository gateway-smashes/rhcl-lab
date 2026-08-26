package io.gatewaysmashes.rhcl.ai;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * OpenAI-compatible model listing on {@code /api/v1/models} (same prefix as
 * {@code banking-api-connectivity} HTTPRoute).
 */
@Path("/api/v1/models")
@ApplicationScoped
public class AiModelsResource {

    @Inject
    OpenAiChatService chatService;

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Response listModels() {
        return Response.ok(chatService.listModels()).build();
    }
}
