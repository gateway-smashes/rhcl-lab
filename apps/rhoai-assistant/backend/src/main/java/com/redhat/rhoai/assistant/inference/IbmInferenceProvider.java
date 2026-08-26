package com.redhat.rhoai.assistant.inference;

import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class IbmInferenceProvider implements InferenceProvider {

    @Override
    public boolean supports(ModelConfiguration model) {
        return "ibm".equalsIgnoreCase(model.provider());
    }

    @Override
    public Multi<InferenceEvent> stream(ModelConfiguration model, InferenceRequest request) {
        return Multi.createFrom().failure(
                new UnsupportedOperationException("IBM provider is not configured in this deployment"));
    }
}
