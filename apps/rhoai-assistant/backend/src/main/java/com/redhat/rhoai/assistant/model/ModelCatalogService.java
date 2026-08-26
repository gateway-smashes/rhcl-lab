package com.redhat.rhoai.assistant.model;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import com.redhat.rhoai.assistant.inference.MaasHttpClientFactory;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

@ApplicationScoped
public class ModelCatalogService {

    private static final Logger LOG = Logger.getLogger(ModelCatalogService.class);

    @ConfigProperty(name = "rhoai.maas.base-url")
    String defaultBaseUrl;

    @ConfigProperty(name = "rhoai.maas.default-model")
    String defaultModelId;

    @ConfigProperty(name = "rhoai.maas.api-key")
    String apiKey;

    @ConfigProperty(name = "rhoai.catalog.seed-path")
    String seedPath;

    @ConfigProperty(name = "rhoai.catalog.sync-on-startup", defaultValue = "true")
    boolean syncOnStartup;

    @ConfigProperty(name = "rhoai.catalog.source", defaultValue = "external-models")
    String catalogSource;

    @Inject
    ObjectMapper objectMapper;

    @Inject
    MaasHttpClientFactory httpClientFactory;

    @Inject
    ExternalModelCatalogSync externalModelCatalogSync;

    private final Map<String, ModelConfiguration> models = new ConcurrentHashMap<>();
    private HttpClient httpClient;

    void onStart(@Observes StartupEvent event) {
        httpClient = httpClientFactory.create(Duration.ofSeconds(15));
        if (!syncOnStartup) {
            loadSeedCatalog();
            return;
        }
        try {
            synchronizeCatalog();
        } catch (Exception e) {
            LOG.warnf("Catalog sync failed (%s): %s", catalogSource, e.getMessage());
            loadSeedCatalog();
        }
    }

    public List<ModelConfiguration> listAll() {
        return models.values().stream()
                .sorted((a, b) -> Integer.compare(a.priority(), b.priority()))
                .collect(Collectors.toList());
    }

    public List<ModelConfiguration> listEnabled() {
        return listAll().stream().filter(ModelConfiguration::enabled).collect(Collectors.toList());
    }

    public Optional<ModelConfiguration> findById(String id) {
        return Optional.ofNullable(models.get(id));
    }

    public void updateStatus(String id, ModelConfiguration.ModelStatus status) {
        findById(id).ifPresent(m -> models.put(id, m.withStatus(status, Instant.now())));
    }

    public void put(ModelConfiguration model) {
        models.put(model.id(), model);
    }

    public List<String> listProviders() {
        return models.values().stream()
                .map(ModelConfiguration::provider)
                .distinct()
                .sorted()
                .collect(Collectors.toList());
    }

    public void synchronizeCatalog() throws Exception {
        if ("external-models".equalsIgnoreCase(catalogSource)) {
            synchronizeFromExternalModels();
            return;
        }
        synchronizeFromGateway();
    }

    public void synchronizeFromExternalModels() throws Exception {
        Map<String, ModelConfiguration> discovered = externalModelCatalogSync.loadFromCluster();
        if (discovered.isEmpty()) {
            throw new IllegalStateException("No ExternalModel resources with ready MaaS endpoints found");
        }
        models.clear();
        models.putAll(discovered);
        LOG.infof("Catalog synchronized from ExternalModel CRs (%d models)", models.size());
    }

    public void synchronizeFromGateway() throws Exception {
        if (apiKey == null || apiKey.isBlank()) {
            throw new IllegalStateException("MAAS_API_KEY is not configured");
        }
        String baseUrl = defaultBaseUrl.endsWith("/")
                ? defaultBaseUrl.substring(0, defaultBaseUrl.length() - 1)
                : defaultBaseUrl;

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(baseUrl + "/models"))
                .timeout(Duration.ofSeconds(15))
                .header("Authorization", "Bearer " + apiKey)
                .GET()
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != 200) {
            throw new RuntimeException("Failed to list models: HTTP " + response.statusCode());
        }

        JsonNode root = objectMapper.readTree(response.body());
        JsonNode data = root.get("data");
        if (data == null || !data.isArray()) {
            return;
        }

        for (JsonNode item : data) {
            String id = item.path("id").asText();
            if (id.isBlank()) {
                continue;
            }
            ModelConfiguration existing = models.get(id);
            ModelConfiguration base = existing != null ? existing : defaultForId(id);
            models.put(id, new ModelConfiguration(
                    id,
                    existing != null ? existing.displayName() : id,
                    base.provider(),
                    base.runtime(),
                    base.origin(),
                    baseUrl,
                    base.externalModelResource(),
                    base.status(),
                    base.priority(),
                    base.contextWindow(),
                    base.streamingSupported(),
                    base.toolsSupported(),
                    base.visionSupported(),
                    base.fallbackModel(),
                    true,
                    base.estimatedInputCost(),
                    base.estimatedOutputCost(),
                    base.lastHealthCheck()));
        }
        LOG.infof("Synchronized %d models from gateway", data.size());
    }

    private void loadSeedCatalog() {
        try (InputStream in = Thread.currentThread().getContextClassLoader().getResourceAsStream(seedPath)) {
            if (in == null) {
                LOG.warnf("Seed catalog not found at %s", seedPath);
                models.put(defaultModelId, defaultForId(defaultModelId));
                return;
            }
            List<Map<String, Object>> seed = objectMapper.readValue(in, new TypeReference<>() {});
            for (Map<String, Object> entry : seed) {
                ModelConfiguration model = mapSeed(entry);
                String endpoint = model.endpoint();
                if (endpoint == null || endpoint.isBlank()) {
                    model = model.withEndpoint(defaultBaseUrl);
                }
                models.put(model.id(), model);
            }
            LOG.infof("Loaded %d models from seed catalog", models.size());
        } catch (Exception e) {
            LOG.errorf(e, "Failed to load seed catalog");
            models.put(defaultModelId, defaultForId(defaultModelId));
        }
    }

    private ModelConfiguration mapSeed(Map<String, Object> entry) {
        return new ModelConfiguration(
                (String) entry.get("id"),
                (String) entry.getOrDefault("displayName", entry.get("id")),
                (String) entry.getOrDefault("provider", "rhoai"),
                (String) entry.getOrDefault("runtime", "litellm"),
                ModelConfiguration.ModelOrigin.valueOf(
                        ((String) entry.getOrDefault("origin", "EXTERNAL")).toUpperCase()),
                (String) entry.getOrDefault("endpoint", defaultBaseUrl),
                (String) entry.get("externalModelResource"),
                ModelConfiguration.ModelStatus.valueOf(
                        ((String) entry.getOrDefault("status", "UNKNOWN")).toUpperCase()),
                ((Number) entry.getOrDefault("priority", 10)).intValue(),
                ((Number) entry.getOrDefault("contextWindow", 32768)).intValue(),
                (Boolean) entry.getOrDefault("streamingSupported", true),
                (Boolean) entry.getOrDefault("toolsSupported", false),
                (Boolean) entry.getOrDefault("visionSupported", false),
                (String) entry.get("fallbackModel"),
                (Boolean) entry.getOrDefault("enabled", true),
                ((Number) entry.getOrDefault("estimatedInputCost", 0.0)).doubleValue(),
                ((Number) entry.getOrDefault("estimatedOutputCost", 0.0)).doubleValue(),
                null);
    }

    private ModelConfiguration defaultForId(String id) {
        return new ModelConfiguration(
                id,
                id,
                "rhoai",
                "litellm",
                ModelConfiguration.ModelOrigin.EXTERNAL,
                defaultBaseUrl,
                null,
                ModelConfiguration.ModelStatus.UNKNOWN,
                10,
                32768,
                true,
                false,
                false,
                null,
                true,
                0.0,
                0.0,
                null);
    }
}
