package com.redhat.rhoai.assistant.chat;

import com.redhat.rhoai.assistant.domain.ChatMessage;
import com.redhat.rhoai.assistant.domain.Conversation;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class ConversationService {

    @Inject
    ConversationRepository repository;

    public Conversation create(String userId, String title, String requestedModel) {
        return repository.save(Conversation.create(userId, title, requestedModel));
    }

    public List<Conversation> listAll() {
        return repository.findAll();
    }

    public Optional<Conversation> get(String id) {
        return repository.findById(id);
    }

    public void delete(String id) {
        repository.delete(id);
    }

    public Conversation updateRequestedModel(String conversationId, String model) {
        Conversation c = repository.findById(conversationId)
                .orElseThrow(() -> new IllegalArgumentException("Conversation not found"));
        return repository.save(c.withRequestedModel(model));
    }

    public Conversation updateActiveModel(String conversationId, String model, String provider) {
        Conversation c = repository.findById(conversationId)
                .orElseThrow(() -> new IllegalArgumentException("Conversation not found"));
        return repository.save(c.withActiveModel(model, provider));
    }

    public ChatMessage addUserMessage(String conversationId, String content) {
        if (!repository.findById(conversationId).isPresent()) {
            throw new IllegalArgumentException("Conversation not found");
        }
        int seq = repository.nextSequence(conversationId);
        return repository.addMessage(ChatMessage.user(conversationId, seq, content));
    }

    public ChatMessage addAssistantMessage(String conversationId, String content) {
        int seq = repository.nextSequence(conversationId);
        return repository.addMessage(ChatMessage.assistant(conversationId, seq, content));
    }

    public List<ChatMessage> getMessages(String conversationId) {
        return repository.findMessages(conversationId);
    }

    public void updateMessageContent(String conversationId, String messageId, String content) {
        repository.updateMessageContent(conversationId, messageId, content);
    }
}
