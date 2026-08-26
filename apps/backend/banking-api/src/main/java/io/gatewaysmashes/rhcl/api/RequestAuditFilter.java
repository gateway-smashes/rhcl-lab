package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.container.ContainerRequestContext;
import jakarta.ws.rs.container.ContainerRequestFilter;
import jakarta.ws.rs.container.ContainerResponseContext;
import jakarta.ws.rs.container.ContainerResponseFilter;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.ext.Provider;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Lightweight access/audit filter that emits one structured INFO log line per
 * request and one per response, with sensitive headers masked. Body content is
 * NOT captured (Quarkus access log + APM tools are better for that); we only
 * log structural information so the gateway can be cross-referenced.
 *
 * Maps to RHCL requirements: 66 (access log + trace correlation),
 * 68 (request/response logging with redaction).
 *
 * Disable with {@code APP_AUDIT_LOG_ENABLED=false}.
 */
@Provider
@ApplicationScoped
public class RequestAuditFilter implements ContainerRequestFilter, ContainerResponseFilter {

    private static final Logger LOG = Logger.getLogger("audit");
    private static final String START_TIME_PROPERTY = "audit.startNanos";

    private static final Set<String> SENSITIVE_HEADERS = Set.of(
            "authorization", "proxy-authorization", "cookie", "set-cookie",
            "x-api-key", "x-auth-token", "x-jwt-assertion");

    @ConfigProperty(name = "app.audit-log.enabled", defaultValue = "true")
    boolean enabled;

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @Inject
    BackendModeHolder modeHolder;

    @Override
    public void filter(ContainerRequestContext ctx) {
        if (!enabled) return;
        ctx.setProperty(START_TIME_PROPERTY, System.nanoTime());
        LOG.infof("req method=%s path=%s consumer=%s traceId=%s mode=%s instance=%s headers=%s",
                ctx.getMethod(),
                ctx.getUriInfo().getPath(),
                safe(ctx.getHeaderString("x-consumer-id")),
                safe(ctx.getHeaderString("x-flow-trace-id")),
                modeHolder.getMode(),
                instanceName,
                maskedHeaders(ctx.getHeaders()));
    }

    @Override
    public void filter(ContainerRequestContext requestContext,
                       ContainerResponseContext responseContext) {
        if (!enabled) return;
        Object start = requestContext.getProperty(START_TIME_PROPERTY);
        long durationMs = start instanceof Long s ? (System.nanoTime() - s) / 1_000_000L : -1L;
        LOG.infof("res method=%s path=%s status=%d durationMs=%d traceId=%s consumer=%s instance=%s",
                requestContext.getMethod(),
                requestContext.getUriInfo().getPath(),
                responseContext.getStatus(),
                durationMs,
                safe(requestContext.getHeaderString("x-flow-trace-id")),
                safe(requestContext.getHeaderString("x-consumer-id")),
                instanceName);
    }

    private static String safe(String value) {
        return value == null ? "-" : value;
    }

    private static Map<String, String> maskedHeaders(MultivaluedMap<String, String> headers) {
        Map<String, String> out = new LinkedHashMap<>();
        for (Map.Entry<String, List<String>> entry : headers.entrySet()) {
            String name = entry.getKey().toLowerCase(Locale.ROOT);
            String value = String.join(",", entry.getValue());
            if (SENSITIVE_HEADERS.contains(name)) {
                out.put(name, mask(value));
            } else {
                out.put(name, value);
            }
        }
        return out;
    }

    private static String mask(String value) {
        if (value == null || value.isEmpty()) return "(empty)";
        if (value.length() <= 8) return "***";
        return value.substring(0, 4) + "***" + value.substring(value.length() - 2);
    }
}
