package com.redhat.rhoai.assistant.model;

import com.redhat.rhoai.assistant.domain.ModelChangeEvent;
import com.redhat.rhoai.assistant.domain.ModelChangeReason;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import com.redhat.rhoai.assistant.execution.ExecutionAuditService;
import com.redhat.rhoai.assistant.inference.InferenceException;
import com.redhat.rhoai.assistant.inference.InferenceProvider;
import com.redhat.rhoai.assistant.inference.InferenceProviderRegistry;
import io.smallrye.mutiny.Multi;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

@ApplicationScoped
public class ModelFallbackService {

    private static final Logger LOG = Logger.getLogger(ModelFallbackService.class);

    @Inject
    ModelRouter modelRouter;

    @Inject
    InferenceProviderRegistry providerRegistry;

    @Inject
    ExecutionAuditService auditService;

    public record FallbackStreamResult(
            Multi<InferenceProvider.InferenceEvent> events,
            List<ModelChangeEvent> modelChanges,
            ModelConfiguration effectiveModel) {}

    public FallbackStreamResult streamWithFallback(
            String executionId,
            String conversationId,
            String requestId,
            ModelConfiguration primary,
            InferenceProvider.InferenceRequest request) {

        List<ModelConfiguration> chain = modelRouter.buildFallbackChain(primary);
        List<ModelChangeEvent> changes = new ArrayList<>();
        AtomicReference<ModelConfiguration> current = new AtomicReference<>(chain.getFirst());
        AtomicReference<String> lastFailure = new AtomicReference<>();

        Multi<InferenceProvider.InferenceEvent> events = tryChain(
                executionId, conversationId, requestId, chain, 0, changes, current, lastFailure, request);

        return new FallbackStreamResult(events, changes, current.get());
    }

    private Multi<InferenceProvider.InferenceEvent> tryChain(
            String executionId,
            String conversationId,
            String requestId,
            List<ModelConfiguration> chain,
            int index,
            List<ModelChangeEvent> changes,
            AtomicReference<ModelConfiguration> current,
            AtomicReference<String> lastFailure,
            InferenceProvider.InferenceRequest request) {

        if (index >= chain.size()) {
            String detail = lastFailure.get();
            String message = detail != null && !detail.isBlank()
                    ? "All models in fallback chain failed. Last error: " + detail
                    : "All models in fallback chain failed";
            return Multi.createFrom().failure(new RuntimeException(message));
        }

        ModelConfiguration model = chain.get(index);
        current.set(model);
        InferenceProvider provider = providerRegistry.resolve(model);

        InferenceProvider.InferenceRequest modelRequest = new InferenceProvider.InferenceRequest(
                requestId,
                model.id(),
                request.messages(),
                request.stream());

        if (index > 0) {
            ModelConfiguration previous = chain.get(index - 1);
            ModelChangeReason reason = ModelChangeReason.MODEL_UNAVAILABLE;
            ModelChangeEvent event = ModelChangeEvent.create(
                    executionId,
                    conversationId,
                    previous.id(),
                    model.id(),
                    previous.provider(),
                    model.provider(),
                    reason);
            changes.add(event);
            auditService.recordModelChange(event);
        }

        return provider.stream(model, modelRequest)
                .onFailure().recoverWithMulti(err -> {
                    if (InferenceException.isRateLimited(err)) {
                        LOG.warnf("Model %s hit rate limit — not falling back", model.id());
                        return Multi.createFrom().failure(err);
                    }
                    String msg = err.getMessage() != null ? err.getMessage() : err.getClass().getSimpleName();
                    lastFailure.set(msg);
                    LOG.warnf("Model %s failed: %s — trying fallback", model.id(), msg);
                    return tryChain(executionId, conversationId, requestId, chain, index + 1, changes, current, lastFailure, request);
                });
    }
}
