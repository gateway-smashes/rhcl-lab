package com.redhat.rhoai.assistant.execution;

import com.redhat.rhoai.assistant.domain.AiExecution;
import com.redhat.rhoai.assistant.domain.ModelChangeEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class ExecutionAuditService {

    @Inject
    ExecutionRepository repository;

    public AiExecution start(AiExecution execution) {
        return repository.save(execution);
    }

    public AiExecution update(AiExecution execution) {
        return repository.save(execution);
    }

    public Optional<AiExecution> findByRequestId(String requestId) {
        return repository.findByRequestId(requestId);
    }

    public Optional<AiExecution> findById(String id) {
        return repository.findById(id);
    }

    public List<AiExecution> findByConversation(String conversationId) {
        return repository.findByConversation(conversationId);
    }

    public void recordModelChange(ModelChangeEvent event) {
        repository.recordModelChange(event);
    }

    public List<ModelChangeEvent> findModelChanges(String conversationId) {
        return repository.findModelChanges(conversationId);
    }
}
