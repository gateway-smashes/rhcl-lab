package io.gatewaysmashes.rhcl.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.inject.Inject;
import jakarta.websocket.Session;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

@ApplicationScoped
public class LiveFeedBroadcaster {

    private final Set<Session> sessions = ConcurrentHashMap.newKeySet();
    private final ScheduledExecutorService heartbeatExecutor = Executors.newSingleThreadScheduledExecutor();

    @Inject
    ObjectMapper objectMapper;

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @PostConstruct
    void startHeartbeat() {
        heartbeatExecutor.scheduleAtFixedRate(() -> {
            if (sessions.isEmpty()) {
                return;
            }
            broadcast(Map.of(
                    "type", "backend.health",
                    "instance", instanceName,
                    "timestamp", OffsetDateTime.now().toString()
            ));
        }, 1, 1, TimeUnit.SECONDS);
    }

    @PreDestroy
    void stopHeartbeat() {
        heartbeatExecutor.shutdownNow();
    }

    public void addSession(Session session) {
        sessions.add(session);
    }

    public void removeSession(Session session) {
        sessions.remove(session);
    }

    public void broadcast(Map<String, Object> payload) {
        try {
            String json = objectMapper.writeValueAsString(payload);
            sessions.stream()
                    .filter(Session::isOpen)
                    .forEach(session -> session.getAsyncRemote().sendText(json));
        } catch (Exception ignored) {
            // keep stream alive even if one event fails serialization
        }
    }
}
