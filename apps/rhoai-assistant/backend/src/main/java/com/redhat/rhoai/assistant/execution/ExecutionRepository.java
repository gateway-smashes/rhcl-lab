package com.redhat.rhoai.assistant.execution;

import com.redhat.rhoai.assistant.domain.AiExecution;
import com.redhat.rhoai.assistant.domain.ModelChangeEvent;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

@ApplicationScoped
public class ExecutionRepository {

    private final Map<String, AiExecution> executions = new ConcurrentHashMap<>();
    private final Map<String, List<ModelChangeEvent>> modelChanges = new ConcurrentHashMap<>();
    private final Map<String, String> requestToExecution = new ConcurrentHashMap<>();

    public AiExecution save(AiExecution execution) {
        executions.put(execution.id(), execution);
        requestToExecution.put(execution.requestId(), execution.id());
        return execution;
    }

    public Optional<AiExecution> findById(String id) {
        return Optional.ofNullable(executions.get(id));
    }

    public Optional<AiExecution> findByRequestId(String requestId) {
        String id = requestToExecution.get(requestId);
        return id != null ? findById(id) : Optional.empty();
    }

    public List<AiExecution> findByConversation(String conversationId) {
        return executions.values().stream()
                .filter(e -> conversationId.equals(e.conversationId()))
                .sorted(Comparator.comparing(AiExecution::startedAt))
                .collect(Collectors.toList());
    }

    public void recordModelChange(ModelChangeEvent event) {
        modelChanges.computeIfAbsent(event.conversationId(), k -> new ArrayList<>()).add(event);
    }

    public List<ModelChangeEvent> findModelChanges(String conversationId) {
        return new ArrayList<>(modelChanges.getOrDefault(conversationId, List.of()));
    }
}
