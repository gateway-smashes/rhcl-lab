package io.gatewaysmashes.rhcl.api;

import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;
import jakarta.websocket.OnClose;
import jakarta.websocket.OnMessage;
import jakarta.websocket.OnOpen;
import jakarta.websocket.Session;
import jakarta.websocket.server.ServerEndpoint;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ServerEndpoint("/ws/live")
public class LiveFeedWebSocket {

    private static final Logger LOG = Logger.getLogger(LiveFeedWebSocket.class);

    @Inject
    LiveFeedBroadcaster broadcaster;

    @ConfigProperty(name = "app.instance-name", defaultValue = "backend-a")
    String instanceName;

    @OnOpen
    public void onOpen(Session session) {
        broadcaster.addSession(session);
    }

    @OnClose
    public void onClose(Session session) {
        broadcaster.removeSession(session);
    }

    /**
     * Echoes ping messages so the PoC Console (Flutter frontend) can compute
     * client→server→client round-trip latency. The frontend sends:
     *   {"type":"ping","pingTimestamp":<epoch-ms>}
     * and expects a response whose payload includes the original
     * pingTimestamp so it can subtract from the current time.
     *
     * Non-ping messages are echoed back under "echo" — useful for validating
     * that the gateway forwards arbitrary frames bidirectionally.
     */
    @OnMessage
    public void onMessage(String message, Session session) {
        LOG.debugf("WS message received (session=%s): %s", session.getId(), message);
        long now = System.currentTimeMillis();
        JsonObject response = new JsonObject()
                .put("serverTime", now)
                .put("instance", instanceName);
        try {
            JsonObject incoming = new JsonObject(message);
            String type = incoming.getString("type", "");
            if ("ping".equals(type)) {
                response.put("type", "pong")
                        .put("pingTimestamp", incoming.getValue("pingTimestamp", now));
            } else {
                response.put("type", "echo")
                        .put("echo", incoming);
            }
        } catch (Exception parseError) {
            LOG.debugf(parseError, "WS message parse failed; echoing raw");
            response.put("type", "echo").put("raw", message);
        }
        String encoded = response.encode();
        try {
            // Use async remote to avoid blocking IO thread + concurrent-send
            // issues with the LiveFeedBroadcaster's scheduled task.
            session.getAsyncRemote().sendText(encoded, result -> {
                if (!result.isOK()) {
                    LOG.warnf(result.getException(), "WS pong/echo send FAILED");
                }
            });
        } catch (Exception sendError) {
            LOG.warnf(sendError, "WS sendText threw synchronously (session=%s)", session.getId());
        }
    }
}
