package com.redhat.rhoai.assistant.api;

import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import com.redhat.rhoai.assistant.model.ModelCatalogService;
import com.redhat.rhoai.assistant.model.ModelHealthService;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Path("/api/v1/models")
@Produces(MediaType.APPLICATION_JSON)
public class ModelsResource {

    @Inject
    ModelCatalogService catalogService;

    @Inject
    ModelHealthService healthService;

    @GET
    public List<Map<String, Object>> list() {
        return catalogService.listAll().stream()
                .map(this::toMap)
                .collect(Collectors.toList());
    }

    @GET
    @Path("/{modelId}")
    public Map<String, Object> get(@PathParam("modelId") String modelId) {
        return catalogService.findById(modelId)
                .map(this::toMap)
                .orElseThrow(NotFoundException::new);
    }

    @GET
    @Path("/{modelId}/health")
    public Map<String, Object> health(@PathParam("modelId") String modelId) {
        ModelConfiguration model = healthService.checkHealth(modelId);
        Map<String, Object> result = toMap(model);
        result.put("healthy", model.status() == ModelConfiguration.ModelStatus.AVAILABLE);
        return result;
    }

    @GET
    @Path("/providers")
    public Map<String, Object> providers() {
        return Map.of("providers", catalogService.listProviders());
    }

    @POST
    @Path("/synchronize")
    public Response synchronize() {
        try {
            catalogService.synchronizeCatalog();
            return Response.ok(Map.of(
                    "status", "synchronized",
                    "count", catalogService.listAll().size())).build();
        } catch (Exception e) {
            return Response.status(502).entity(Map.of("error", e.getMessage())).build();
        }
    }

    private Map<String, Object> toMap(ModelConfiguration m) {
        Map<String, Object> map = new HashMap<>();
        map.put("id", m.id());
        map.put("displayName", m.displayName());
        map.put("provider", m.provider());
        map.put("runtime", m.runtime());
        map.put("origin", m.origin().name());
        map.put("endpoint", m.endpoint());
        map.put("externalModelResource", m.externalModelResource());
        map.put("status", m.status().name());
        map.put("priority", m.priority());
        map.put("contextWindow", m.contextWindow());
        map.put("streamingSupported", m.streamingSupported());
        map.put("toolsSupported", m.toolsSupported());
        map.put("visionSupported", m.visionSupported());
        map.put("fallbackModel", m.fallbackModel());
        map.put("enabled", m.enabled());
        map.put("estimatedInputCost", m.estimatedInputCost());
        map.put("estimatedOutputCost", m.estimatedOutputCost());
        map.put("lastHealthCheck", m.lastHealthCheck() != null ? m.lastHealthCheck().toString() : null);
        return map;
    }
}
