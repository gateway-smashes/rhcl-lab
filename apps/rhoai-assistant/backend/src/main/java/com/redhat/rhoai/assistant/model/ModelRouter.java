package com.redhat.rhoai.assistant.model;

import com.redhat.rhoai.assistant.domain.ModelChangeReason;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

@ApplicationScoped
public class ModelRouter {

    @Inject
    ModelSelectionPolicy selectionPolicy;

    public ModelSelectionPolicy.SelectionResult route(String requestedModel) {
        return selectionPolicy.select(requestedModel, true);
    }

    public List<ModelConfiguration> buildFallbackChain(ModelConfiguration primary) {
        Set<String> seen = new LinkedHashSet<>();
        List<ModelConfiguration> chain = new ArrayList<>();
        ModelConfiguration current = primary;
        while (current != null && seen.add(current.id())) {
            chain.add(current);
            current = selectionPolicy.fallbackFor(current).orElse(null);
        }
        return chain;
    }

    public ModelChangeReason mapFailureReason(Throwable error) {
        String msg = error.getMessage() != null ? error.getMessage().toLowerCase() : "";
        if (msg.contains("timeout")) {
            return ModelChangeReason.REQUEST_TIMEOUT;
        }
        if (msg.contains("503") || msg.contains("capacity")) {
            return ModelChangeReason.CAPACITY_EXHAUSTED;
        }
        if (msg.contains("context") || msg.contains("token")) {
            return ModelChangeReason.CONTEXT_LIMIT_EXCEEDED;
        }
        return ModelChangeReason.MODEL_UNAVAILABLE;
    }
}
