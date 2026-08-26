package com.redhat.rhoai.assistant.chat;

import com.redhat.rhoai.assistant.domain.ChatMessage;
import com.redhat.rhoai.assistant.domain.Conversation;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

@ApplicationScoped
public class ConversationRepository {

    private final Map<String, Conversation> conversations = new ConcurrentHashMap<>();
    private final Map<String, List<ChatMessage>> messages = new ConcurrentHashMap<>();

    public Conversation save(Conversation conversation) {
        conversations.put(conversation.id(), conversation);
        messages.putIfAbsent(conversation.id(), new ArrayList<>());
        return conversation;
    }

    public Optional<Conversation> findById(String id) {
        return Optional.ofNullable(conversations.get(id));
    }

    public List<Conversation> findAll() {
        return conversations.values().stream()
                .sorted(Comparator.comparing(Conversation::updatedAt).reversed())
                .collect(Collectors.toList());
    }

    public void delete(String id) {
        conversations.remove(id);
        messages.remove(id);
    }

    public ChatMessage addMessage(ChatMessage message) {
        messages.computeIfAbsent(message.conversationId(), k -> new ArrayList<>()).add(message);
        return message;
    }

    public List<ChatMessage> findMessages(String conversationId) {
        return new ArrayList<>(messages.getOrDefault(conversationId, List.of()));
    }

    public void updateMessageContent(String conversationId, String messageId, String content) {
        List<ChatMessage> list = messages.get(conversationId);
        if (list == null) {
            return;
        }
        for (int i = 0; i < list.size(); i++) {
            ChatMessage msg = list.get(i);
            if (msg.id().equals(messageId)) {
                list.set(i, new ChatMessage(
                        msg.id(), msg.conversationId(), msg.role(), content, msg.sequence(), msg.createdAt()));
                return;
            }
        }
    }

    public int nextSequence(String conversationId) {
        return findMessages(conversationId).size() + 1;
    }
}
