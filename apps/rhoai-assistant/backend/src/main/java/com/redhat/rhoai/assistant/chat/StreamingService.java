package com.redhat.rhoai.assistant.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.redhat.rhoai.assistant.domain.AiExecution;
import com.redhat.rhoai.assistant.domain.ModelChangeEvent;
import com.redhat.rhoai.assistant.execution.ExecutionAuditService;
import com.redhat.rhoai.assistant.inference.InferenceErrors;
import com.redhat.rhoai.assistant.inference.InferenceProvider;
import com.redhat.rhoai.assistant.model.ModelFallbackService;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.subscription.MultiEmitter;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.sse.OutboundSseEvent;
import jakarta.ws.rs.sse.Sse;
import org.jboss.logging.Logger;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

@ApplicationScoped
public class StreamingService {

    private static final Logger LOG = Logger.getLogger(StreamingService.class);

    @Inject
    ObjectMapper objectMapper;

    @Inject
    ConversationService conversationService;

    @Inject
    ExecutionAuditService auditService;

    @Inject
    Sse sse;

    private final Map<String, StreamSession> sessions = new ConcurrentHashMap<>();

    public void register(
            String requestId,
            ModelFallbackService.FallbackStreamResult streamResult,
            AiExecution execution,
            String assistantMessageId) {
        sessions.put(requestId, new StreamSession(streamResult, execution, assistantMessageId));
    }

    public Multi<OutboundSseEvent> events(String requestId) {
        StreamSession session = sessions.get(requestId);
        if (session == null) {
            return Multi.createFrom().failure(new IllegalArgumentException("Unknown requestId: " + requestId));
        }
        return Multi.createFrom().<OutboundSseEvent>emitter(emitter -> startProcessing(requestId, session, emitter));
    }

    public void cancel(String requestId) {
        StreamSession session = sessions.remove(requestId);
        if (session != null) {
            session.cancelled.set(true);
        }
    }

    private void startProcessing(
            String requestId,
            StreamSession session,
            MultiEmitter<? super OutboundSseEvent> emitter) {
        StringBuilder content = new StringBuilder();
        java.util.concurrent.atomic.AtomicReference<AiExecution> currentRef =
                new java.util.concurrent.atomic.AtomicReference<>(session.execution);

        try {
            AiExecution current = currentRef.get();
            emitter.emit(sseEvent("model.selected", Map.of(
                    "requestId", requestId,
                    "requestedModel", current.requestedModel(),
                    "selectedModel", current.selectedModel(),
                    "provider", current.provider(),
                    "runtime", current.runtime(),
                    "reason", current.selectionReason())));

            for (ModelChangeEvent change : session.streamResult.modelChanges()) {
                emitter.emit(sseEvent("model.changed", Map.of(
                        "requestId", requestId,
                        "fromModel", change.fromModel(),
                        "toModel", change.toModel(),
                        "reason", change.reason().name())));
            }

            session.streamResult.events().subscribe().with(
                    event -> {
                        if (session.cancelled.get()) {
                            return;
                        }
                        switch (event.type()) {
                            case CONTENT_DELTA -> {
                                String delta = (String) event.data().get("content");
                                content.append(delta);
                                emitter.emit(sseEvent("message.delta", event.data()));
                            }
                            case EFFECTIVE_MODEL -> {
                                String effective = (String) event.data().get("effectiveModel");
                                currentRef.updateAndGet(e -> e.withEffectiveModel(effective, true));
                                auditService.update(currentRef.get());
                            }
                            case USAGE -> {
                                int input = (Integer) event.data().get("inputTokens");
                                int output = (Integer) event.data().get("outputTokens");
                                long latency = ((Number) event.data().get("latencyMs")).longValue();
                                long ttft = ((Number) event.data().get("timeToFirstTokenMs")).longValue();
                                double cost = ((Number) event.data().get("estimatedCost")).doubleValue();
                                currentRef.updateAndGet(e -> e.withUsage(input, output, cost, latency, ttft));
                                auditService.update(currentRef.get());
                                emitter.emit(sseEvent("usage.completed", event.data()));
                            }
                            case ERROR -> {
                                Object errMsg = event.data().get("message");
                                String message = errMsg != null ? errMsg.toString() : event.data().toString();
                                failStream(requestId, session, emitter, currentRef, content, new RuntimeException(message));
                            }
                        }
                    },
                    err -> failStream(requestId, session, emitter, currentRef, content, err),
                    () -> {
                        if (!session.cancelled.get()) {
                            AiExecution done = currentRef.get();
                            conversationService.updateMessageContent(
                                    done.conversationId(), session.assistantMessageId, content.toString());
                            currentRef.set(auditService.update(done.completed()));
                            emitter.emit(sseEvent("message.completed", Map.of(
                                    "requestId", requestId,
                                    "messageId", session.assistantMessageId,
                                    "status", "COMPLETED")));
                        }
                        emitter.complete();
                        sessions.remove(requestId);
                    });
        } catch (Exception e) {
            LOG.errorf(e, "Stream setup failed for %s", requestId);
            failStream(requestId, session, emitter, currentRef, content, e);
        }
    }

    private void failStream(
            String requestId,
            StreamSession session,
            MultiEmitter<? super OutboundSseEvent> emitter,
            java.util.concurrent.atomic.AtomicReference<AiExecution> currentRef,
            StringBuilder content,
            Throwable err) {
        LOG.errorf(err, "Stream failed for %s", requestId);
        auditService.update(currentRef.get().failed());
        Map<String, Object> errorPayload = InferenceErrors.toErrorPayload(requestId, err);
        String message = (String) errorPayload.get("message");
        if (content.isEmpty()) {
            conversationService.updateMessageContent(
                    currentRef.get().conversationId(), session.assistantMessageId, message);
        }
        emitter.emit(sseEvent("error", errorPayload));
        Map<String, Object> completed = new HashMap<>();
        completed.put("requestId", requestId);
        completed.put("messageId", session.assistantMessageId);
        completed.put("status", "FAILED");
        completed.put("error", message);
        if (errorPayload.containsKey("statusCode")) {
            completed.put("statusCode", errorPayload.get("statusCode"));
        }
        if (errorPayload.containsKey("code")) {
            completed.put("code", errorPayload.get("code"));
        }
        emitter.emit(sseEvent("message.completed", completed));
        emitter.complete();
        sessions.remove(requestId);
    }

    private OutboundSseEvent sseEvent(String name, Map<String, Object> data) {
        try {
            return sse.newEventBuilder()
                    .name(name)
                    .mediaType(MediaType.APPLICATION_JSON_TYPE)
                    .data(objectMapper.writeValueAsString(data))
                    .build();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static class StreamSession {
        final ModelFallbackService.FallbackStreamResult streamResult;
        final AiExecution execution;
        final String assistantMessageId;
        final AtomicBoolean cancelled = new AtomicBoolean(false);

        StreamSession(ModelFallbackService.FallbackStreamResult streamResult, AiExecution execution, String assistantMessageId) {
            this.streamResult = streamResult;
            this.execution = execution;
            this.assistantMessageId = assistantMessageId;
        }
    }
}
