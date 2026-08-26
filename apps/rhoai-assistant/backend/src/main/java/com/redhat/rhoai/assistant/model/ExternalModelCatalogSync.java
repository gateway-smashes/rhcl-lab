package com.redhat.rhoai.assistant.model;

import com.fasterxml.jackson.databind.JsonNode;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.HashMap;
import java.util.Map;

@ApplicationScoped
public class ExternalModelCatalogSync {

  private static final Logger LOG = Logger.getLogger(ExternalModelCatalogSync.class);

  @ConfigProperty(name = "rhoai.external-models.namespace", defaultValue = "external-models")
  String externalModelsNamespace;

  @ConfigProperty(name = "rhoai.external-models.api-group", defaultValue = "maas.opendatahub.io")
  String apiGroup;

  @ConfigProperty(name = "rhoai.external-models.api-version", defaultValue = "v1alpha1")
  String apiVersion;

  @Inject
  KubernetesApiClient kubernetesApiClient;

  public Map<String, ModelConfiguration> loadFromCluster() throws Exception {
    JsonNode externalModels = kubernetesApiClient.listCustomResources(
        apiGroup, apiVersion, externalModelsNamespace, "externalmodels");
    JsonNode modelRefs = kubernetesApiClient.listCustomResources(
        apiGroup, apiVersion, externalModelsNamespace, "maasmodelrefs");

    Map<String, String> endpointsByName = new HashMap<>();
    for (JsonNode item : modelRefs.path("items")) {
      String name = item.path("metadata").path("name").asText();
      String endpoint = item.path("status").path("endpoint").asText("");
      if (!name.isBlank() && !endpoint.isBlank()) {
        endpointsByName.put(name, normalizeOpenAiBaseUrl(endpoint));
      }
    }

    Map<String, ModelConfiguration> models = new HashMap<>();
    for (JsonNode item : externalModels.path("items")) {
      String resourceName = item.path("metadata").path("name").asText();
      if (resourceName.isBlank()) {
        continue;
      }
      JsonNode spec = item.path("spec");
      String targetModel = spec.path("targetModel").asText("");
      if (targetModel.isBlank()) {
        continue;
      }
      String endpoint = endpointsByName.get(resourceName);
      if (endpoint == null || endpoint.isBlank()) {
        LOG.warnf("Skipping ExternalModel %s — MaaSModelRef endpoint not ready", resourceName);
        continue;
      }

      String provider = spec.path("provider").asText("openai");
      String displayName = humanize(resourceName, targetModel);
      models.put(targetModel, new ModelConfiguration(
          targetModel,
          displayName,
          "rhoai",
          provider,
          ModelConfiguration.ModelOrigin.EXTERNAL,
          endpoint,
          resourceName,
          ModelConfiguration.ModelStatus.UNKNOWN,
          priorityFor(resourceName),
          32768,
          true,
          false,
          false,
          null,
          true,
          0.0,
          0.0,
          null));
    }

    LOG.infof("Loaded %d models from ExternalModel CRs in %s", models.size(), externalModelsNamespace);
    return models;
  }

  static String normalizeOpenAiBaseUrl(String gatewayEndpoint) {
    String base = gatewayEndpoint.endsWith("/")
        ? gatewayEndpoint.substring(0, gatewayEndpoint.length() - 1)
        : gatewayEndpoint;
    if (base.endsWith("/v1")) {
      return base;
    }
    return base + "/v1";
  }

  private static int priorityFor(String resourceName) {
    if (resourceName.contains("deepseek")) {
      return 5;
    }
    if (resourceName.contains("llama-31")) {
      return 10;
    }
    if (resourceName.contains("llama-scout")) {
      return 15;
    }
    return 20;
  }

  private static String humanize(String resourceName, String targetModel) {
    return resourceName
        .replace("-external", "")
        .replace('-', ' ')
        .replace("llama", "Llama")
        .replace("deepseek", "DeepSeek")
        + " (" + targetModel + ")";
  }
}
