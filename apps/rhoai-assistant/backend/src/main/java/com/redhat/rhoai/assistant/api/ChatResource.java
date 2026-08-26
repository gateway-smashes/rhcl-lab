package com.redhat.rhoai.assistant.api;

import com.redhat.rhoai.assistant.chat.ChatService;
import com.redhat.rhoai.assistant.chat.ConversationService;
import com.redhat.rhoai.assistant.chat.StreamingService;
import com.redhat.rhoai.assistant.domain.ChatMessage;
import com.redhat.rhoai.assistant.domain.Conversation;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.sse.OutboundSseEvent;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Path("/api/v1/conversations")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class ChatResource {

    @Inject
    ConversationService conversationService;

    @Inject
    ChatService chatService;

    @Inject
    StreamingService streamingService;

    @POST
    public Response create(Map<String, Object> body) {
        String userId = stringVal(body, "userId", "anonymous");
        String title = stringVal(body, "title", null);
        String requestedModel = stringVal(body, "requestedModel", "auto");
        Conversation c = conversationService.create(userId, title, requestedModel);
        return Response.status(201).entity(toConversationMap(c)).build();
    }

    @GET
    public List<Map<String, Object>> list() {
        return conversationService.listAll().stream()
                .map(this::toConversationMap)
                .collect(Collectors.toList());
    }

    @GET
    @Path("/{conversationId}")
    public Map<String, Object> get(@PathParam("conversationId") String conversationId) {
        Conversation c = conversationService.get(conversationId)
                .orElseThrow(() -> new NotFoundException("Conversation not found"));
        Map<String, Object> result = toConversationMap(c);
        result.put("messages", conversationService.getMessages(conversationId).stream()
                .map(this::toMessageMap)
                .collect(Collectors.toList()));
        return result;
    }

    @DELETE
    @Path("/{conversationId}")
    public Response delete(@PathParam("conversationId") String conversationId) {
        conversationService.delete(conversationId);
        return Response.noContent().build();
    }

    @POST
    @Path("/{conversationId}/messages")
    public Map<String, Object> postMessage(
            @PathParam("conversationId") String conversationId,
            Map<String, Object> body) {
        String content = stringVal(body, "content", null);
        if (content == null || content.isBlank()) {
            throw new BadRequestException("content is required");
        }
        String requestedModel = stringVal(body, "requestedModel", null);
        ChatService.MessageSubmission submission = chatService.submitMessage(
                conversationId, content, requestedModel);
        Map<String, Object> result = new HashMap<>();
        result.put("requestId", submission.requestId());
        result.put("messageId", submission.messageId());
        result.put("executionId", submission.executionId());
        result.put("requestedModel", submission.requestedModel());
        result.put("selectedModel", submission.selectedModel());
        result.put("provider", submission.provider());
        result.put("runtime", submission.runtime());
        result.put("selectionReason", submission.selectionReason());
        return result;
    }

    @GET
    @Path("/{conversationId}/stream")
    @Produces(MediaType.SERVER_SENT_EVENTS)
    public io.smallrye.mutiny.Multi<OutboundSseEvent> stream(
            @PathParam("conversationId") String conversationId,
            @QueryParam("requestId") String requestId) {
        if (requestId == null || requestId.isBlank()) {
            throw new BadRequestException("requestId query parameter is required");
        }
        conversationService.get(conversationId)
                .orElseThrow(() -> new NotFoundException("Conversation not found"));
        return streamingService.events(requestId);
    }

    @POST
    @Path("/{conversationId}/cancel")
    public Map<String, Object> cancel(
            @PathParam("conversationId") String conversationId,
            Map<String, Object> body) {
        String requestId = stringVal(body, "requestId", null);
        if (requestId == null) {
            throw new BadRequestException("requestId is required");
        }
        chatService.cancel(conversationId, requestId);
        return Map.of("requestId", requestId, "status", "CANCELLED");
    }

    @GET
    @Path("/{conversationId}/active-model")
    public Map<String, Object> activeModel(@PathParam("conversationId") String conversationId) {
        return chatService.activeModel(conversationId);
    }

    @GET
    @Path("/{conversationId}/model-events")
    public List<Map<String, Object>> modelEvents(@PathParam("conversationId") String conversationId) {
        return chatService.modelEvents(conversationId).stream()
                .map(e -> Map.<String, Object>of(
                        "id", e.id(),
                        "executionId", e.executionId(),
                        "fromModel", e.fromModel(),
                        "toModel", e.toModel(),
                        "fromProvider", e.fromProvider() != null ? e.fromProvider() : "",
                        "toProvider", e.toProvider() != null ? e.toProvider() : "",
                        "reason", e.reason().name(),
                        "createdAt", e.createdAt().toString()))
                .collect(Collectors.toList());
    }

    private Map<String, Object> toConversationMap(Conversation c) {
        Map<String, Object> map = new HashMap<>();
        map.put("id", c.id());
        map.put("userId", c.userId());
        map.put("title", c.title());
        map.put("requestedModel", c.requestedModel());
        map.put("activeModel", c.activeModel());
        map.put("activeProvider", c.activeProvider());
        map.put("createdAt", c.createdAt().toString());
        map.put("updatedAt", c.updatedAt().toString());
        return map;
    }

    private Map<String, Object> toMessageMap(ChatMessage m) {
        return Map.of(
                "id", m.id(),
                "role", m.role().name().toLowerCase(),
                "content", m.content(),
                "sequence", m.sequence(),
                "createdAt", m.createdAt().toString());
    }

    private String stringVal(Map<String, Object> body, String key, String defaultVal) {
        Object v = body != null ? body.get(key) : null;
        return v != null ? v.toString() : defaultVal;
    }
}
