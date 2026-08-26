package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.Cookie;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.UriInfo;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Collectors;

@Path("/api/echo")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class EchoResource {

    private static final Logger LOG = Logger.getLogger(EchoResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @GET
    public Map<String, Object> echoGet(@Context HttpHeaders headers, @Context UriInfo uriInfo) {
        return buildResponse("GET", null, headers, uriInfo);
    }

    @POST
    public Map<String, Object> echoPost(Map<String, Object> body,
                                        @Context HttpHeaders headers,
                                        @Context UriInfo uriInfo) {
        return buildResponse("POST", body, headers, uriInfo);
    }

    private Map<String, Object> buildResponse(String method, Map<String, Object> body,
                                              HttpHeaders headers, UriInfo uriInfo) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("instance", instanceName);
        response.put("timestamp", OffsetDateTime.now().toString());
        response.put("method", method);
        response.put("requestUri", uriInfo.getRequestUri().toString());
        response.put("queryParameters", uriInfo.getQueryParameters());
        response.put("headers", headers.getRequestHeaders());
        response.put("cookies", headers.getCookies()
                .entrySet()
                .stream()
                .collect(Collectors.toMap(Map.Entry::getKey, e -> cookieToMap(e.getValue()))));
        response.put("requestBody", body == null ? Map.of() : body);
        response.put("sampleResponseHeaders", Map.of(
                "x-echo-instance", instanceName,
                "x-echo-method", method
        ));
        LOG.infof("echo request method=%s uri=%s queryParameters=%s headerNames=%s cookies=%s body=%s",
            method,
            response.get("requestUri"),
            response.get("queryParameters"),
            headers.getRequestHeaders().keySet(),
            headers.getCookies().keySet(),
            response.get("requestBody"));
        return response;
    }

    private Map<String, Object> cookieToMap(Cookie cookie) {
        return Map.of(
                "name", cookie.getName(),
                "value", cookie.getValue(),
                "path", cookie.getPath() == null ? "/" : cookie.getPath()
        );
    }
}
