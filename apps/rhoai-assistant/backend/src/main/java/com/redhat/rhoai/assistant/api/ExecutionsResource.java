package com.redhat.rhoai.assistant.api;

import com.redhat.rhoai.assistant.domain.AiExecution;
import com.redhat.rhoai.assistant.execution.ExecutionAuditService;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

import java.util.HashMap;
import java.util.Map;

@Path("/api/v1/executions")
@Produces(MediaType.APPLICATION_JSON)
public class ExecutionsResource {

    @Inject
    ExecutionAuditService auditService;

    @GET
    @Path("/{executionId}")
    public Map<String, Object> get(@PathParam("executionId") String executionId) {
        AiExecution e = auditService.findById(executionId)
                .orElseThrow(NotFoundException::new);
        return toMap(e);
    }

    private Map<String, Object> toMap(AiExecution e) {
        Map<String, Object> map = new HashMap<>();
        map.put("id", e.id());
        map.put("conversationId", e.conversationId());
        map.put("messageId", e.messageId());
        map.put("requestId", e.requestId());
        map.put("requestedModel", e.requestedModel());
        map.put("selectedModel", e.selectedModel());
        map.put("effectiveModel", e.effectiveModel());
        map.put("provider", e.provider());
        map.put("runtime", e.runtime());
        map.put("selectionReason", e.selectionReason());
        map.put("modelVerified", e.modelVerified());
        map.put("inputTokens", e.inputTokens());
        map.put("outputTokens", e.outputTokens());
        map.put("totalTokens", e.totalTokens());
        map.put("estimatedCost", e.estimatedCost());
        map.put("latencyMs", e.latencyMs());
        map.put("timeToFirstTokenMs", e.timeToFirstTokenMs());
        map.put("status", e.status().name());
        map.put("startedAt", e.startedAt().toString());
        map.put("completedAt", e.completedAt() != null ? e.completedAt().toString() : null);
        return map;
    }
}
