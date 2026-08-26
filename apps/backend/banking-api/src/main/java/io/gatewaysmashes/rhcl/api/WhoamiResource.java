package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Echoes auth/identity-related headers injected by the gateway after OIDC
 * introspection / JWT validation. The backend never validates anything — it
 * only surfaces what the gateway passed through, so RHCL AuthPolicy enforcement
 * can be observed end-to-end.
 *
 * Maps to RHCL requirements: 30 (proxy with full request access),
 * 67 (OAuth2 introspection + scopes), 71 (OIDC/JWT).
 */
@Path("/api/whoami")
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class WhoamiResource {

    private static final Logger LOG = Logger.getLogger(WhoamiResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @ConfigProperty(name = "app.test-endpoints.enabled", defaultValue = "true")
    boolean enabled;

    @GET
    public Map<String, Object> whoami(@Context HttpHeaders headers) {
        if (!enabled) {
            throw new NotFoundException();
        }

        Map<String, List<String>> all = headers.getRequestHeaders();
        Map<String, String> jwtHeaders = new TreeMap<>();
        Map<String, String> forwarded = new LinkedHashMap<>();

        for (Map.Entry<String, List<String>> entry : all.entrySet()) {
            String name = entry.getKey().toLowerCase();
            String value = String.join(",", entry.getValue());
            if (name.startsWith("x-jwt-") || name.startsWith("x-auth-")) {
                jwtHeaders.put(name, value);
            }
            if (name.startsWith("x-forwarded-")) {
                forwarded.put(name, value);
            }
        }

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("instance", instanceName);
        response.put("timestamp", OffsetDateTime.now().toString());
        response.put("authorization", headers.getHeaderString("authorization"));
        response.put("consumer", headers.getHeaderString("x-consumer-id"));
        response.put("forwarded", forwarded);
        response.put("jwt", jwtHeaders);
        response.put("allHeaders", all);

        LOG.infof("whoami instance=%s consumer=%s authorizationPresent=%s jwtHeaders=%s forwarded=%s",
                instanceName,
                response.get("consumer"),
                response.get("authorization") != null,
                jwtHeaders.keySet(),
                forwarded.keySet());

        return response;
    }
}
