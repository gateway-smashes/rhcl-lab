package io.gatewaysmashes.rhcl.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ThreadLocalRandom;

/**
 * PoC validation endpoints for failure / latency / payload-size injection.
 * Exposed under {@code /api/test/*} and gated by {@code app.test-endpoints.enabled}.
 *
 * Maps to RHCL requirements: 1 (circuit breaker), 13 (per-endpoint timeout),
 * 22/25 (introspection 5xx behavior), 34/35 (error logs), 38 (trace
 * propagation — {@code /api/test/propagate} chama o ledger-api downstream),
 * 44 (enrichment).
 */
@Path("/api/test")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class TestResource {

    private static final Logger LOG = Logger.getLogger(TestResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @ConfigProperty(name = "app.test-endpoints.enabled", defaultValue = "true")
    boolean enabled;

    @Inject
    BackendModeHolder holder;

    // REQ 038 — destinos do microserviço downstream (ledger-api). A propagação
    // do contexto de trace nestas chamadas é feita pelo AGENTE Java injetado
    // (sem código): ele extrai o `traceparent` de entrada e o reinjeta na
    // chamada de saída abaixo. Aqui só configuramos PARA ONDE chamar.
    @ConfigProperty(name = "app.propagation.ledger.direct-url", defaultValue = "http://localhost:8081")
    String ledgerDirectUrl;

    // Optional: o gateway-url pode ser vazio/ausente (ex.: sem connectivity link,
    // ou em pods que não são o chamador). Optional<String> faz o SmallRye Config
    // mapear valor vazio/ausente para Optional.empty em vez de falhar a conversão
    // para String (que derruba o startup — quebrava o banking-api-v2).
    @ConfigProperty(name = "app.propagation.ledger.gateway-url")
    Optional<String> ledgerGatewayUrl;

    @Inject
    ObjectMapper mapper;

    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    private void ensureEnabled() {
        if (!enabled) {
            throw new NotFoundException();
        }
    }

    @GET
    @Path("/echo-error")
    public Response echoError(@QueryParam("status") Integer status,
                              @QueryParam("delay") Long delay,
                              @QueryParam("size") Integer size) {
        ensureEnabled();
        int httpStatus = status == null ? 500 : status;
        long delayMs = delay == null ? 0L : delay;
        int payloadSize = size == null ? 0 : Math.max(0, size);

        if (delayMs > 0) {
            try {
                Thread.sleep(delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("instance", instanceName);
        body.put("timestamp", OffsetDateTime.now().toString());
        body.put("requestedStatus", httpStatus);
        body.put("requestedDelayMs", delayMs);
        body.put("requestedSize", payloadSize);
        body.put("payload", payloadSize > 0 ? "x".repeat(payloadSize) : "");

        LOG.infof("test echo-error instance=%s status=%d delayMs=%d size=%d",
                instanceName, httpStatus, delayMs, payloadSize);

        return Response.status(httpStatus)
                .entity(body)
                .header("x-test-instance", instanceName)
                .header("x-test-status", String.valueOf(httpStatus))
                .build();
    }

    @GET
    @Path("/flaky")
    public Response flaky(@QueryParam("failRate") Double failRate) {
        ensureEnabled();
        double requested = failRate == null ? 0.0d : Math.max(0.0d, Math.min(1.0d, failRate));
        double effective = Math.max(requested, holder.effectiveFailRate());
        boolean fail = ThreadLocalRandom.current().nextDouble() < effective;

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("instance", instanceName);
        body.put("timestamp", OffsetDateTime.now().toString());
        body.put("requestedFailRate", requested);
        body.put("effectiveFailRate", effective);
        body.put("mode", holder.getMode());
        body.put("outcome", fail ? "fail" : "ok");

        int status = fail ? 503 : 200;
        LOG.infof("test flaky instance=%s mode=%s effectiveFailRate=%.3f outcome=%s",
                instanceName, holder.getMode(), effective, fail ? "fail" : "ok");

        return Response.status(status)
                .entity(body)
                .header("x-test-instance", instanceName)
                .build();
    }

    @GET
    @Path("/mode")
    public Map<String, Object> getMode() {
        ensureEnabled();
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("instance", instanceName);
        data.put("timestamp", OffsetDateTime.now().toString());
        data.putAll(holder.snapshot());
        return data;
    }

    @POST
    @Path("/mode")
    public Map<String, Object> setMode(Map<String, Object> request) {
        ensureEnabled();
        if (request != null) {
            Object newMode = request.get("mode");
            if (newMode != null) {
                holder.setMode(String.valueOf(newMode));
            }
            Object newFailRate = request.get("failRate");
            if (newFailRate != null) {
                holder.setFailRate(Double.parseDouble(String.valueOf(newFailRate)));
            }
        }
        LOG.infof("test mode updated instance=%s mode=%s failRate=%.3f",
                instanceName, holder.getMode(), holder.getFailRate());
        return getMode();
    }

    /**
     * REQ 038 — gera propagação de traces backend→backend. Recebe a chamada do
     * gateway (que já injetou o `traceparent`) e chama o microserviço
     * downstream {@code ledger-api} {@code calls} vezes. O agente Java injetado
     * propaga o contexto W3C automaticamente, de modo que o trace resultante
     * encadeia {@code rhcl-gateway → banking-api → ledger-api} sob um único
     * Trace ID.
     *
     * @param target {@code direct} (DNS de Service, default) ou {@code gateway}
     *               (via HTTPRoute/gateway RHCL)
     * @param calls  número de chamadas downstream (1..20)
     */
    @GET
    @Path("/propagate")
    public Response propagate(@QueryParam("target") String target,
                              @QueryParam("calls") Integer calls,
                              @HeaderParam("traceparent") String traceparent) {
        ensureEnabled();
        String mode = (target == null || target.isBlank()) ? "direct" : target.trim().toLowerCase();
        int n = calls == null ? 1 : Math.max(1, Math.min(20, calls));
        String base = "gateway".equals(mode) ? ledgerGatewayUrl.orElse("") : ledgerDirectUrl;

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("instance", instanceName);
        result.put("target", mode);
        result.put("downstreamBase", base);
        result.put("calls", n);
        result.put("timestamp", OffsetDateTime.now().toString());
        // Trace ID do trace iniciado no gateway e propagado até aqui — a UI usa
        // este id para abrir o trace em Observe → Traces no console OpenShift.
        result.put("traceparent", traceparent);
        result.put("traceId", traceIdFrom(traceparent));

        if (base == null || base.isBlank()) {
            result.put("error", "downstream base URL not configured for target '" + mode
                    + "' (set LEDGER_GATEWAY_URL / LEDGER_DIRECT_URL)");
            return Response.status(Response.Status.BAD_GATEWAY).entity(result).build();
        }

        URI uri = URI.create(base.replaceAll("/+$", "") + "/ledger/record");
        List<Map<String, Object>> downstream = new ArrayList<>();
        int ok = 0;
        int failed = 0;
        for (int i = 0; i < n; i++) {
            Map<String, Object> call = new LinkedHashMap<>();
            String payload = "{\"amount\":" + ThreadLocalRandom.current().nextInt(1, 10000)
                    + ",\"account\":\"BR-" + ThreadLocalRandom.current().nextInt(1000, 9999)
                    + "\",\"source\":\"banking-api\"}";
            long started = System.nanoTime();
            try {
                // Não setamos `traceparent` manualmente: o agente Java injetado
                // propaga o contexto W3C automaticamente nesta chamada de saída.
                HttpRequest req = HttpRequest.newBuilder(uri)
                        .timeout(Duration.ofSeconds(5))
                        .header("content-type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(payload))
                        .build();
                HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
                long ms = (System.nanoTime() - started) / 1_000_000L;
                call.put("status", resp.statusCode());
                call.put("latencyMs", ms);
                Map<String, Object> body = parseJson(resp.body());
                if (body != null) {
                    call.put("entryId", body.get("entryId"));
                    call.put("downstreamTraceId", body.get("traceId"));
                    call.put("downstreamInstance", body.get("instance"));
                }
                if (resp.statusCode() >= 200 && resp.statusCode() < 300) {
                    ok++;
                } else {
                    failed++;
                }
            } catch (Exception e) {
                long ms = (System.nanoTime() - started) / 1_000_000L;
                call.put("latencyMs", ms);
                call.put("error", e.getClass().getSimpleName() + ": " + e.getMessage());
                failed++;
            }
            downstream.add(call);
        }

        Map<String, Object> summary = new LinkedHashMap<>();
        summary.put("ok", ok);
        summary.put("failed", failed);
        result.put("summary", summary);
        result.put("downstream", downstream);

        LOG.infof("test propagate instance=%s target=%s calls=%d ok=%d failed=%d traceId=%s",
                instanceName, mode, n, ok, failed,
                traceIdFrom(traceparent) == null ? "-" : traceIdFrom(traceparent));

        int status = (failed > 0 && ok == 0) ? 502 : 200;
        return Response.status(status).entity(result).build();
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> parseJson(String body) {
        if (body == null || body.isBlank()) {
            return null;
        }
        try {
            return mapper.readValue(body, Map.class);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Extrai o trace-id (32 hex do meio) do header W3C `traceparent`
     * (formato: {@code version-traceid-spanid-flags}).
     */
    static String traceIdFrom(String traceparent) {
        if (traceparent == null) {
            return null;
        }
        String[] parts = traceparent.split("-");
        if (parts.length < 4 || parts[1].length() != 32) {
            return null;
        }
        return parts[1];
    }
}
