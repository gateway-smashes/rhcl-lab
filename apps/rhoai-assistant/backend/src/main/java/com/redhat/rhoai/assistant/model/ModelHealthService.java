package com.redhat.rhoai.assistant.model;

import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import com.redhat.rhoai.assistant.inference.MaasAuthTokenProvider;
import com.redhat.rhoai.assistant.inference.MaasHttpClientFactory;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;

@ApplicationScoped
public class ModelHealthService {

    private static final Logger LOG = Logger.getLogger(ModelHealthService.class);

    @Inject
    ModelCatalogService catalogService;

    @Inject
    MaasHttpClientFactory httpClientFactory;

    @Inject
    MaasAuthTokenProvider authTokenProvider;

    @ConfigProperty(name = "rhoai.maas.api-key")
    String apiKey;

    private HttpClient httpClient;

    @jakarta.annotation.PostConstruct
    void init() {
        httpClient = httpClientFactory.create(Duration.ofSeconds(10));
    }

    @Scheduled(every = "{rhoai.health.poll-interval}")
    void pollAll() {
        try {
            authTokenProvider.bearerToken();
        } catch (Exception e) {
            return;
        }
        for (ModelConfiguration model : catalogService.listEnabled()) {
            checkHealth(model);
        }
    }

    public ModelConfiguration checkHealth(String modelId) {
        return catalogService.findById(modelId)
                .map(this::checkHealth)
                .orElseThrow(() -> new IllegalArgumentException("Model not found: " + modelId));
    }

    public ModelConfiguration checkHealth(ModelConfiguration model) {
        if (apiKey == null || apiKey.isBlank()) {
            try {
                authTokenProvider.bearerToken();
            } catch (Exception e) {
                catalogService.updateStatus(model.id(), ModelConfiguration.ModelStatus.UNKNOWN);
                return catalogService.findById(model.id()).orElse(model);
            }
        }

        String baseUrl = model.endpoint();
        if (baseUrl.endsWith("/")) {
            baseUrl = baseUrl.substring(0, baseUrl.length() - 1);
        }

        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + "/models"))
                    .timeout(Duration.ofSeconds(5))
                    .header("Authorization", "Bearer " + authTokenProvider.bearerToken())
                    .GET()
                    .build();

            HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
            ModelConfiguration.ModelStatus status = response.statusCode() == 200
                    ? ModelConfiguration.ModelStatus.AVAILABLE
                    : ModelConfiguration.ModelStatus.UNAVAILABLE;
            catalogService.put(model.withStatus(status, Instant.now()));
        } catch (Exception e) {
            LOG.debugf("Health check failed for %s: %s", model.id(), e.getMessage());
            catalogService.put(model.withStatus(ModelConfiguration.ModelStatus.UNAVAILABLE, Instant.now()));
        }
        return catalogService.findById(model.id()).orElse(model);
    }
}
