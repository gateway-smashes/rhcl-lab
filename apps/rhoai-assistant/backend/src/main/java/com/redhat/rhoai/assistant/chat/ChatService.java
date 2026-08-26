package com.redhat.rhoai.assistant.chat;

import com.redhat.rhoai.assistant.domain.AiExecution;
import com.redhat.rhoai.assistant.domain.ChatMessage;
import com.redhat.rhoai.assistant.domain.ModelChangeEvent;
import com.redhat.rhoai.assistant.domain.ModelConfiguration;
import com.redhat.rhoai.assistant.execution.ExecutionAuditService;
import com.redhat.rhoai.assistant.inference.InferenceProvider;
import com.redhat.rhoai.assistant.model.ModelFallbackService;
import com.redhat.rhoai.assistant.model.ModelRouter;
import com.redhat.rhoai.assistant.model.ModelSelectionPolicy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@ApplicationScoped
public class ChatService {

    @Inject
    ConversationService conversationService;

    @Inject
    ModelRouter modelRouter;

    @Inject
    ModelFallbackService fallbackService;

    @Inject
    ExecutionAuditService auditService;

    @Inject
    StreamingService streamingService;

    @ConfigProperty(name = "chat.history.max-messages")
    int maxHistoryMessages;

    @ConfigProperty(name = "chat.system-prompt")
    String systemPrompt;

    public record MessageSubmission(
            String requestId,
            String messageId,
            String executionId,
            String requestedModel,
            String selectedModel,
            String provider,
            String runtime,
            String selectionReason) {}

    public MessageSubmission submitMessage(String conversationId, String content, String requestedModel) {
        ConversationService conv = conversationService;
        var conversation = conv.get(conversationId)
                .orElseThrow(() -> new IllegalArgumentException("Conversation not found"));

        String effectiveRequested = requestedModel != null && !requestedModel.isBlank()
                ? requestedModel
                : conversation.requestedModel();

        ChatMessage userMessage = conv.addUserMessage(conversationId, content);
        ModelSelectionPolicy.SelectionResult selection = modelRouter.route(effectiveRequested);

        String requestId = UUID.randomUUID().toString();
        ChatMessage assistantPlaceholder = conv.addAssistantMessage(conversationId, "");

        AiExecution execution = AiExecution.start(
                conversationId,
                assistantPlaceholder.id(),
                requestId,
                effectiveRequested,
                selection.model().id(),
                selection.model().provider(),
                selection.model().runtime(),
                selection.reason().name());

        auditService.start(execution);
        conversationService.updateActiveModel(
                conversationId, selection.model().id(), selection.model().provider());

        List<Map<String, String>> messages = buildPromptMessages(conversationId);

        InferenceProvider.InferenceRequest inferenceRequest = new InferenceProvider.InferenceRequest(
                requestId,
                selection.model().id(),
                messages,
                true);

        ModelFallbackService.FallbackStreamResult streamResult = fallbackService.streamWithFallback(
                execution.id(),
                conversationId,
                requestId,
                selection.model(),
                inferenceRequest);

        streamingService.register(requestId, streamResult, execution, assistantPlaceholder.id());

        return new MessageSubmission(
                requestId,
                assistantPlaceholder.id(),
                execution.id(),
                effectiveRequested,
                selection.model().id(),
                selection.model().provider(),
                selection.model().runtime(),
                selection.reason().name());
    }

    private List<Map<String, String>> buildPromptMessages(String conversationId) {
        List<Map<String, String>> result = new ArrayList<>();
        result.add(Map.of("role", "system", "content", systemPrompt));

        List<ChatMessage> history = conversationService.getMessages(conversationId);
        int start = Math.max(0, history.size() - maxHistoryMessages);
        for (int i = start; i < history.size(); i++) {
            ChatMessage msg = history.get(i);
            if (msg.content() == null || msg.content().isBlank()) {
                continue;
            }
            String role = msg.role() == ChatMessage.MessageRole.ASSISTANT ? "assistant" : "user";
            result.add(Map.of("role", role, "content", msg.content()));
        }
        return result;
    }

    public void cancel(String conversationId, String requestId) {
        streamingService.cancel(requestId);
        auditService.findByRequestId(requestId).ifPresent(e -> auditService.update(e.cancelled()));
    }

    public Map<String, Object> activeModel(String conversationId) {
        return conversationService.get(conversationId)
                .map(c -> {
                    Map<String, Object> map = new HashMap<>();
                    map.put("conversationId", conversationId);
                    map.put("requestedModel", c.requestedModel());
                    map.put("activeModel", c.activeModel());
                    map.put("activeProvider", c.activeProvider());
                    return map;
                })
                .orElseThrow(() -> new IllegalArgumentException("Conversation not found"));
    }

    public List<ModelChangeEvent> modelEvents(String conversationId) {
        return auditService.findModelChanges(conversationId);
    }
}
