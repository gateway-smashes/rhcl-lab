package io.gatewaysmashes.rhcl.api;

import io.quarkiverse.mcp.server.Tool;
import io.quarkiverse.mcp.server.ToolArg;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * MCP server tools that expose the banking-api domain to MCP-aware clients
 * (Backstage MCP gateway, Claude Desktop, MCP Inspector, etc.).
 *
 * Tools are auto-registered by the quarkus-mcp-server-http extension and
 * served at <code>POST /mcp</code> (Streamable HTTP transport, MCP 2025-03-26)
 * and <code>/mcp/sse</code> (legacy SSE transport).
 *
 * The tools delegate to the in-process CDI beans rather than calling the REST
 * layer over HTTP — this keeps the MCP entrypoint cheap and avoids any extra
 * network hop, while still exercising the same business logic.
 */
@ApplicationScoped
public class BankingMcpTools {

    private static final Logger LOG = Logger.getLogger(BankingMcpTools.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @Inject
    BankingResource bankingResource;

    @Inject
    BackendModeHolder modeHolder;

    @Tool(description = "Return the current account summary (balances, investments, totals) for the requested API version (v1 or v2). Use this to inspect a customer's portfolio without performing any change.")
    public Map<String, Object> getAccountSummary(
            @ToolArg(description = "API version to query: 'v1' or 'v2'. Defaults to 'v1'.", required = false) String version) {
        String v = (version == null || version.isBlank()) ? "v1" : version.trim().toLowerCase();
        if (!"v1".equals(v) && !"v2".equals(v)) {
            throw new IllegalArgumentException("version must be 'v1' or 'v2'");
        }
        LOG.infof("mcp tool getAccountSummary version=%s instance=%s", v, instanceName);
        return bankingResource.summarySnapshot(v);
    }

    @Tool(description = "Simulate a transfer between two banks. Returns the transfer status (RECEIVED/AUTHORIZED/REJECTED) and the resulting balance snapshot. Use 'EXTERNAL' as toBank to simulate an outbound transfer.")
    public Map<String, Object> simulateTransfer(
            @ToolArg(description = "API version: 'v1' or 'v2'. Defaults to 'v1'.", required = false) String version,
            @ToolArg(description = "Source bank identifier (e.g. 'Example Bank', 'Beta Bank').") String fromBank,
            @ToolArg(description = "Destination bank identifier or 'EXTERNAL' for an outbound transfer.") String toBank,
            @ToolArg(description = "Amount to transfer, as a decimal string (e.g. '1500.00').") String amount,
            @ToolArg(description = "Optional client-generated trace id for correlation.", required = false) String clientTraceId) {
        String v = (version == null || version.isBlank()) ? "v1" : version.trim().toLowerCase();
        if (!"v1".equals(v) && !"v2".equals(v)) {
            throw new IllegalArgumentException("version must be 'v1' or 'v2'");
        }
        if (fromBank == null || fromBank.isBlank()) {
            throw new IllegalArgumentException("fromBank is required");
        }
        if (toBank == null || toBank.isBlank()) {
            throw new IllegalArgumentException("toBank is required");
        }
        if (amount == null || amount.isBlank()) {
            throw new IllegalArgumentException("amount is required");
        }
        Map<String, Object> request = new LinkedHashMap<>();
        request.put("fromBank", fromBank);
        request.put("toBank", toBank);
        request.put("amount", amount);
        request.put("clientTraceId",
                (clientTraceId == null || clientTraceId.isBlank())
                        ? "mcp-" + UUID.randomUUID()
                        : clientTraceId);
        LOG.infof("mcp tool simulateTransfer version=%s payload=%s", v, request);
        return "v2".equals(v) ? bankingResource.transferV2(request) : bankingResource.transferV1(request);
    }

    @Tool(description = "Return the current backend operational mode (healthy/degraded/down), the configured fail-rate, and whether readiness probes will pass. Useful for chaos and resilience demos.")
    public Map<String, Object> getBackendMode() {
        Map<String, Object> snapshot = new LinkedHashMap<>(modeHolder.snapshot());
        snapshot.put("instance", instanceName);
        return snapshot;
    }

    @Tool(description = "Update the backend operational mode and/or fail-rate at runtime. Use to drive circuit-breaker, outlier-detection and readiness-flip demos.")
    public Map<String, Object> setBackendMode(
            @ToolArg(description = "New mode: 'healthy', 'degraded' or 'down'. Optional — omit to keep the current value.", required = false) String mode,
            @ToolArg(description = "Fail rate between 0.0 and 1.0. Optional — omit to keep the current value.", required = false) Double failRate) {
        if (mode != null && !mode.isBlank()) {
            modeHolder.setMode(mode.trim().toLowerCase());
        }
        if (failRate != null) {
            modeHolder.setFailRate(failRate);
        }
        Map<String, Object> snapshot = new LinkedHashMap<>(modeHolder.snapshot());
        snapshot.put("instance", instanceName);
        LOG.infof("mcp tool setBackendMode -> %s", snapshot);
        return snapshot;
    }
}
