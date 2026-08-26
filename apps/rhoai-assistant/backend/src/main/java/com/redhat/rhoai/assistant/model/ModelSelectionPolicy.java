package com.redhat.rhoai.assistant.model;

import com.redhat.rhoai.assistant.domain.ModelChangeReason;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.stream.Collectors;

@ApplicationScoped
public class ModelSelectionPolicy {

    @Inject
    ModelCatalogService catalogService;

    public record SelectionResult(
            ModelConfiguration model,
            ModelChangeReason reason) {}

    public SelectionResult select(String requestedModel, boolean requireStreaming) {
        if (requestedModel != null && !requestedModel.isBlank() && !"auto".equalsIgnoreCase(requestedModel)) {
            ModelConfiguration manual = catalogService.findById(requestedModel)
                    .filter(ModelConfiguration::enabled)
                    .orElseThrow(() -> new IllegalArgumentException("Requested model not available: " + requestedModel));
            return new SelectionResult(manual, ModelChangeReason.MANUAL_SELECTION);
        }

        List<ModelConfiguration> candidates = catalogService.listEnabled().stream()
                .filter(m -> !requireStreaming || m.streamingSupported())
                .filter(m -> m.status() == ModelConfiguration.ModelStatus.AVAILABLE
                        || m.status() == ModelConfiguration.ModelStatus.UNKNOWN)
                .sorted(Comparator.comparingInt(ModelConfiguration::priority))
                .collect(Collectors.toList());

        if (candidates.isEmpty()) {
            candidates = catalogService.listEnabled().stream()
                    .sorted(Comparator.comparingInt(ModelConfiguration::priority))
                    .collect(Collectors.toList());
        }

        if (candidates.isEmpty()) {
            throw new IllegalStateException("No enabled models in catalog");
        }

        return new SelectionResult(candidates.getFirst(), ModelChangeReason.DEFAULT_PRIORITY);
    }

    public Optional<ModelConfiguration> fallbackFor(ModelConfiguration model) {
        if (model.fallbackModel() == null || model.fallbackModel().isBlank()) {
            return Optional.empty();
        }
        return catalogService.findById(model.fallbackModel()).filter(ModelConfiguration::enabled);
    }
}
