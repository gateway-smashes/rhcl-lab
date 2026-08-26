package io.gatewaysmashes.rhcl.api;

import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import io.micrometer.core.instrument.MeterRegistry;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

@Path("/api")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class BankingResource {

    private static final Logger LOG = Logger.getLogger(BankingResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @Inject
    LiveFeedBroadcaster liveFeedBroadcaster;

    @Inject
    MeterRegistry meterRegistry;

    private final Map<String, Map<String, Object>> v1Banks = new ConcurrentHashMap<>();
    private final Map<String, Map<String, Object>> v2Banks = new ConcurrentHashMap<>();
    private final Map<String, BigDecimal> v1InitialBalances = new ConcurrentHashMap<>();
    private final Map<String, BigDecimal> v2InitialBalances = new ConcurrentHashMap<>();
    private BigDecimal v1Investments = new BigDecimal("15000.00");
    private BigDecimal v2Investments = new BigDecimal("18250.50");
    private final ScheduledExecutorService asyncExecutor = Executors.newSingleThreadScheduledExecutor();

    public BankingResource() {
        seedData();
    }

    @PreDestroy
    void shutdownExecutor() {
        asyncExecutor.shutdownNow();
    }

    @GET
    @Path("/v1/cors")
    public Map<String, Object> corsDemoV1(@HeaderParam("Origin") String origin,
                                          @HeaderParam("Referer") String referer) {
        // Endpoint deliberadamente "nu": não emite Access-Control-Allow-* nem
        // outros cabeçalhos de CORS. Quando chamado por um navegador a partir
        // de origem diferente, o próprio navegador bloqueia a resposta. O
        // gateway, à frente, é quem injeta os cabeçalhos via
        // ResponseHeaderModifier — vê tests/req014/manifests/httproute-cors.yaml.
        LOG.infof("cors demo version=v1 instance=%s origin=%s referer=%s",
                instanceName, origin, referer);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("apiVersion", "v1");
        body.put("instance", instanceName);
        body.put("backendTag", backendTag("v1"));
        body.put("message", "CORS demo endpoint — backend não envia cabeçalhos CORS por padrão.");
        body.put("origin", origin == null ? "" : origin);
        body.put("referer", referer == null ? "" : referer);
        body.put("timestamp", OffsetDateTime.now().toString());
        return body;
    }

    @GET
    @Path("/v1/timeout")
    public Map<String, Object> timeoutDemoV1() {
        long delayMs = 3000L;
        long t0 = System.currentTimeMillis();
        LOG.infof("timeout demo start version=v1 instance=%s delayMs=%d", instanceName, delayMs);
        try {
            Thread.sleep(delayMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        long elapsed = System.currentTimeMillis() - t0;
        String message = "Resposta do backend após " + elapsed + " ms (delay configurado: " + delayMs + " ms)";
        LOG.infof("timeout demo end version=v1 instance=%s elapsedMs=%d message=%s",
                instanceName, elapsed, message);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("apiVersion", "v1");
        body.put("instance", instanceName);
        body.put("backendTag", backendTag("v1"));
        body.put("requestedDelayMs", delayMs);
        body.put("elapsedMs", elapsed);
        body.put("message", message);
        body.put("timestamp", OffsetDateTime.now().toString());
        return body;
    }

    @GET
    @Path("/v1/accounts/summary")
    public Map<String, Object> summaryV1() {
        Map<String, Object> response = baseSummary("v1", snapshot(v1Banks), v1Investments,
            Map.of("pix", true, "transfers", true, "scheduledTransfers", false));
        LOG.infof("summary served version=%s backendTag=%s banks=%s investments=%s accountTotal=%s grandTotal=%s features=%s",
            response.get("apiVersion"),
            response.get("backendTag"),
            response.get("banks"),
            response.get("investments"),
            response.get("accountTotal"),
            response.get("grandTotal"),
            response.get("features"));
        return response;
    }

    @GET
    @Path("/v2/accounts/summary")
    public Map<String, Object> summaryV2() {
        Map<String, Object> response = baseSummary("v2", snapshot(v2Banks), v2Investments,
            Map.of("pix", true, "transfers", true, "scheduledTransfers", true));
        LOG.infof("summary served version=%s backendTag=%s banks=%s investments=%s accountTotal=%s grandTotal=%s features=%s",
            response.get("apiVersion"),
            response.get("backendTag"),
            response.get("banks"),
            response.get("investments"),
            response.get("accountTotal"),
            response.get("grandTotal"),
            response.get("features"));
        return response;
    }

    /**
     * Public accessor used by the gRPC service to reuse the in-memory banks data.
     * Returns the same map shape produced by the REST endpoints.
     */
    public Map<String, Object> summarySnapshot(String version) {
        if ("v2".equals(version)) {
            return baseSummary("v2", snapshot(v2Banks), v2Investments,
                Map.of("pix", true, "transfers", true, "scheduledTransfers", true));
        }
        return baseSummary("v1", snapshot(v1Banks), v1Investments,
            Map.of("pix", true, "transfers", true, "scheduledTransfers", false));
    }

    @POST
    @Path("/v1/transfers")
    public Map<String, Object> transferV1(Map<String, Object> request) {
        return applyTransfer("v1", request, "RECEIVED");
    }

    @POST
    @Path("/v2/transfers")
    public Map<String, Object> transferV2(Map<String, Object> request) {
        return applyTransfer("v2", request, "AUTHORIZED");
    }

    @POST
    @Path("/v1/accounts/reset")
    public synchronized Map<String, Object> resetV1Account(Map<String, Object> request) {
        String bankName = String.valueOf(request.getOrDefault("bankName", ""));
        if (bankName.isBlank()) {
            return Map.of(
                    "apiVersion", "v1",
                    "instance", instanceName,
                    "backendTag", backendTag("v1"),
                    "status", "REJECTED",
                    "reason", "bankName is required",
                    "receivedAt", OffsetDateTime.now().toString()
            );
        }

        Map<String, Object> bank = v1Banks.get(bankName);
        BigDecimal initialBalance = v1InitialBalances.get(bankName);
        if (bank == null || initialBalance == null) {
            return Map.of(
                    "apiVersion", "v1",
                    "instance", instanceName,
                    "backendTag", backendTag("v1"),
                    "status", "REJECTED",
                    "reason", "Unknown bank",
                    "bankName", bankName,
                    "receivedAt", OffsetDateTime.now().toString()
            );
        }

        bank.put("balance", initialBalance);
        List<Map<String, Object>> bankSnapshot = snapshot(v1Banks);
        BigDecimal accountTotal = bankSnapshot.stream()
                .map(entry -> new BigDecimal(entry.get("balance").toString()))
                .reduce(BigDecimal.ZERO, BigDecimal::add);

        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", "balance.updated");
        event.put("apiVersion", "v1");
        event.put("instance", instanceName);
        event.put("backendTag", backendTag("v1"));
        event.put("traceId", String.valueOf(request.getOrDefault("clientTraceId", "reset")));
        event.put("amount", BigDecimal.ZERO);
        event.put("accountTotal", accountTotal);
        event.put("banks", bankSnapshot);
        event.put("timestamp", OffsetDateTime.now().toString());
        liveFeedBroadcaster.broadcast(event);

        return Map.of(
                "apiVersion", "v1",
                "instance", instanceName,
                "backendTag", backendTag("v1"),
                "status", "RESET",
                "bankName", bankName,
                "balance", initialBalance,
                "receivedAt", OffsetDateTime.now().toString()
        );
    }

    private synchronized Map<String, Object> applyTransfer(String version, Map<String, Object> request, String status) {
        Map<String, Map<String, Object>> banks = "v1".equals(version) ? v1Banks : v2Banks;
        String fromBank = String.valueOf(request.getOrDefault("fromBank", ""));
        String toBank = String.valueOf(request.getOrDefault("toBank", ""));
        BigDecimal amount = toBigDecimal(request.getOrDefault("amount", "0"));
        String traceId = String.valueOf(request.getOrDefault("clientTraceId", "n/a"));
        String transferId = UUID.randomUUID().toString();

        LOG.infof("transfer requested version=%s transferId=%s traceId=%s fromBank=%s toBank=%s amount=%s payload=%s",
            version, transferId, traceId, fromBank, toBank, amount, request);

        Map<String, Object> from = banks.get(fromBank);
        Map<String, Object> to = banks.get(toBank);
        boolean externalTransfer = to == null && "EXTERNAL".equalsIgnoreCase(toBank);

        if (from == null || (!externalTransfer && to == null)) {
            LOG.warnf("transfer rejected version=%s transferId=%s traceId=%s fromBank=%s toBank=%s amount=%s reason=unknown-bank availableBanks=%s",
                version, transferId, traceId, fromBank, toBank, amount, banks.keySet());
            meterRegistry.counter("banking_transfers_total",
                "version", version, "status", "REJECTED", "reason", "unknown-bank",
                "instance", instanceName).increment();
            return Map.of(
                    "apiVersion", version,
                    "instance", instanceName,
                    "backendTag", backendTag(version),
                "transferId", transferId,
                    "status", "REJECTED",
                    "reason", "Unknown bank in transfer request",
                    "receivedAt", OffsetDateTime.now().toString(),
                    "request", request
            );
        }

        BigDecimal fromBalance = (BigDecimal) from.get("balance");
        if (fromBalance.compareTo(amount) < 0) {
            LOG.warnf("transfer rejected version=%s transferId=%s traceId=%s fromBank=%s toBank=%s amount=%s currentBalance=%s reason=insufficient-balance",
                version, transferId, traceId, fromBank, toBank, amount, fromBalance);
            meterRegistry.counter("banking_transfers_total",
                "version", version, "status", "REJECTED", "reason", "insufficient-balance",
                "instance", instanceName).increment();
            return Map.of(
                    "apiVersion", version,
                    "instance", instanceName,
                    "backendTag", backendTag(version),
                "transferId", transferId,
                    "status", "REJECTED",
                    "reason", "Insufficient balance",
                    "receivedAt", OffsetDateTime.now().toString(),
                    "request", request
            );
        }

        BigDecimal fromUpdatedBalance = fromBalance.subtract(amount);
        from.put("balance", fromUpdatedBalance);
        BigDecimal toUpdatedBalance = null;
        if (!externalTransfer) {
            toUpdatedBalance = ((BigDecimal) to.get("balance")).add(amount);
            to.put("balance", toUpdatedBalance);
        }

        LOG.infof("transfer accepted version=%s transferId=%s traceId=%s fromBank=%s toBank=%s amount=%s externalTransfer=%s fromBalanceAfter=%s",
            version, transferId, traceId, fromBank, toBank, amount, externalTransfer, fromUpdatedBalance);
        if (toUpdatedBalance != null) {
            LOG.infof("transfer destination balance updated version=%s transferId=%s toBank=%s toBalanceAfter=%s",
                version, transferId, toBank, toUpdatedBalance);
        }
        meterRegistry.counter("banking_transfers_total",
            "version", version, "status", externalTransfer ? "SENT_EXTERNAL" : status, "reason", "none",
            "instance", instanceName).increment();
        broadcastTransferLifecycle(transferId, version, fromBank, toBank, amount, traceId, banks);

        if (externalTransfer) {
            LOG.infof("transfer dispatched externally version=%s transferId=%s traceId=%s target=%s",
                version, transferId, traceId, toBank);
            return Map.of(
                    "apiVersion", version,
                    "instance", instanceName,
                    "backendTag", backendTag(version),
                    "transferId", transferId,
                    "status", "SENT_EXTERNAL",
                    "receivedAt", OffsetDateTime.now().toString(),
                    "request", request
            );
        }

        return transferResponse(version, request, status, transferId);
    }

    private List<Map<String, Object>> snapshot(Map<String, Map<String, Object>> source) {
        return source.values().stream()
                .map(entry -> Map.<String, Object>of(
                        "bankName", entry.get("bankName"),
                        "account", entry.get("account"),
                        "balance", entry.get("balance")
                ))
                .toList();
    }

    private Map<String, Object> baseSummary(String version, List<Map<String, Object>> banks,
                                            BigDecimal investments, Map<String, Object> features) {
        BigDecimal accountTotal = banks.stream()
                .map(entry -> new BigDecimal(entry.get("balance").toString()))
                .reduce(BigDecimal.ZERO, BigDecimal::add);

        return Map.of(
                "apiVersion", version,
                "instance", instanceName,
                "backendTag", backendTag(version),
                "timestamp", OffsetDateTime.now().toString(),
                "banks", banks,
                "investments", investments,
                "accountTotal", accountTotal,
                "grandTotal", accountTotal.add(investments),
                "features", features
        );
    }

    private Map<String, Object> bank(String name, String account, BigDecimal balance) {
        Map<String, Object> bank = new LinkedHashMap<>();
        bank.put("bankName", name);
        bank.put("account", account);
        bank.put("balance", balance);
        return bank;
    }

    private Map<String, Object> transferResponse(String version, Map<String, Object> request,
                                                 String status, String transferId) {
        return Map.of(
                "apiVersion", version,
                "instance", instanceName,
                "backendTag", backendTag(version),
                "transferId", transferId,
                "status", status,
                "receivedAt", OffsetDateTime.now().toString(),
                "request", request
        );
    }

    private String backendTag(String version) {
        return version + "@" + instanceName;
    }

    private BigDecimal toBigDecimal(Object value) {
        if (value == null) {
            return BigDecimal.ZERO;
        }
        return new BigDecimal(value.toString());
    }

    private void broadcastTransferLifecycle(String transferId, String version,
                                             String fromBank, String toBank, BigDecimal amount,
                                             String traceId, Map<String, Map<String, Object>> banks) {
        LOG.infof("transfer lifecycle scheduled version=%s transferId=%s traceId=%s fromBank=%s toBank=%s amount=%s",
            version, transferId, traceId, fromBank, toBank, amount);
        liveFeedBroadcaster.broadcast(
                transferEvent("transfer.pending", transferId, version, fromBank, toBank, amount, traceId));

        asyncExecutor.schedule(() -> liveFeedBroadcaster.broadcast(
                transferEvent("transfer.processing", transferId, version, fromBank, toBank, amount, traceId)),
                600, TimeUnit.MILLISECONDS);

        asyncExecutor.schedule(() -> liveFeedBroadcaster.broadcast(
                transferEvent("transfer.completed", transferId, version, fromBank, toBank, amount, traceId)),
                1500, TimeUnit.MILLISECONDS);

        asyncExecutor.schedule(() -> {
            List<Map<String, Object>> bankSnapshot = snapshot(banks);
            BigDecimal accountTotal = bankSnapshot.stream()
                    .map(e -> new BigDecimal(e.get("balance").toString()))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            Map<String, Object> event = new LinkedHashMap<>();
            event.put("type", "balance.updated");
            event.put("apiVersion", version);
            event.put("instance", instanceName);
            event.put("backendTag", backendTag(version));
            event.put("traceId", traceId);
            event.put("transferId", transferId);
            event.put("amount", amount);
            event.put("accountTotal", accountTotal);
            event.put("banks", bankSnapshot);
            event.put("timestamp", OffsetDateTime.now().toString());
            liveFeedBroadcaster.broadcast(event);
        }, 2000, TimeUnit.MILLISECONDS);
    }

    private Map<String, Object> transferEvent(String type, String transferId, String version,
                                              String fromBank, String toBank, BigDecimal amount,
                                              String traceId) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", type);
        event.put("transferId", transferId);
        event.put("apiVersion", version);
        event.put("instance", instanceName);
        event.put("backendTag", backendTag(version));
        event.put("traceId", traceId);
        event.put("fromBank", fromBank);
        event.put("toBank", toBank);
        event.put("amount", amount);
        event.put("timestamp", OffsetDateTime.now().toString());
        return event;
    }

    private void seedData() {
        List<Map<String, Object>> initialV1 = List.of(
                bank("Example Bank", "1234-5", new BigDecimal("3200.43")),
                bank("Caixa", "8888-9", new BigDecimal("790.80")),
                bank("Beta Bank", "1010-1", new BigDecimal("2450.20"))
        );
        List<Map<String, Object>> initialV2 = List.of(
                bank("Example Bank", "1234-5", new BigDecimal("3350.00")),
                bank("Caixa", "8888-9", new BigDecimal("700.10")),
                bank("Beta Bank", "1010-1", new BigDecimal("2611.40")),
                bank("Inter", "3333-3", new BigDecimal("440.00"))
        );

        initialV1.forEach(entry -> v1Banks.put(entry.get("bankName").toString(), new LinkedHashMap<>(entry)));
        initialV2.forEach(entry -> v2Banks.put(entry.get("bankName").toString(), new LinkedHashMap<>(entry)));
        initialV1.forEach(entry -> v1InitialBalances.put(
                entry.get("bankName").toString(),
                new BigDecimal(entry.get("balance").toString())));
        initialV2.forEach(entry -> v2InitialBalances.put(
                entry.get("bankName").toString(),
                new BigDecimal(entry.get("balance").toString())));
    }
}
