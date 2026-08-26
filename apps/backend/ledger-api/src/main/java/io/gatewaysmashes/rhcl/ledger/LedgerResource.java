package io.gatewaysmashes.rhcl.ledger;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Downstream "ledger" microservice chamado pelo banking-api (REQ 038 —
 * propagação de traces). Recebe um pedido de lançamento contábil, executa um
 * trabalho simbólico (latência pequena) e devolve o resultado.
 *
 * NÃO há código OpenTelemetry aqui: o agente Java injetado pelo OpenTelemetry
 * Operator (anotação instrumentation.opentelemetry.io/inject-java no Deployment)
 * cria automaticamente o span server, continuando o trace propagado pelo
 * banking-api via header W3C `traceparent`. O endpoint apenas ecoa o
 * `traceparent`/`traceId` recebido para que a UI consiga linkar o trace.
 */
@Path("/ledger")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class LedgerResource {

    private static final Logger LOG = Logger.getLogger(LedgerResource.class);

    @ConfigProperty(name = "app.instance-name", defaultValue = "ledger-api")
    String instanceName;

    @GET
    @Path("/info")
    public Map<String, Object> info() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("service", "ledger-api");
        data.put("instance", instanceName);
        data.put("timestamp", OffsetDateTime.now().toString());
        return data;
    }

    @POST
    @Path("/record")
    public Map<String, Object> record(Map<String, Object> request,
                                      @HeaderParam("traceparent") String traceparent) {
        // Trabalho simbólico: latência aleatória curta para o span ter duração visível.
        long workMs = ThreadLocalRandom.current().nextLong(5, 40);
        try {
            Thread.sleep(workMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        String entryId = "LE-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase();
        String traceId = traceIdFrom(traceparent);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", "ledger-api");
        body.put("instance", instanceName);
        body.put("operation", "record");
        body.put("entryId", entryId);
        body.put("status", "POSTED");
        body.put("processedMs", workMs);
        body.put("receivedTraceparent", traceparent);
        body.put("traceId", traceId);
        body.put("receivedAt", OffsetDateTime.now().toString());
        body.put("request", request == null ? Map.of() : request);

        LOG.infof("ledger record instance=%s entryId=%s traceId=%s workMs=%d",
                instanceName, entryId, traceId == null ? "-" : traceId, workMs);
        return body;
    }

    /**
     * Extrai o trace-id (32 hex do meio) do header W3C `traceparent`
     * (formato: {@code version-traceid-spanid-flags}). Retorna null se ausente
     * ou malformado.
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
