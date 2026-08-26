package com.redhat.rhoai.assistant.inference;

import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;

@ApplicationScoped
public class InferenceProviderRegistry {

    @Inject
    Instance<InferenceProvider> providers;

    public InferenceProvider resolve(ModelConfiguration model) {
        for (InferenceProvider provider : providers) {
            if (provider.supports(model)) {
                return provider;
            }
        }
        throw new IllegalArgumentException("No inference provider for model " + model.id());
    }
}
