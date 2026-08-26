package io.gatewaysmashes.rhcl.config;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import org.eclipse.microprofile.config.spi.ConfigSource;

/**
 * Narrows quarkus.http.cors.origins to {@code *.<RHCL_ZONE_ROOT_DOMAIN>} when
 * the env var is set, leaving the application.properties default ("/.*\/")
 * untouched otherwise. This makes req014 demonstrably fail without the gateway:
 * a browser at e.g. tester.4players.com.br hitting the backend directly will be
 * blocked by CORS, while in-zone callers and the gateway-proxied flow keep
 * working.
 */
public class CorsOriginsConfigSource implements ConfigSource {

    private static final String PROPERTY = "quarkus.http.cors.origins";
    private static final String ENV_VAR = "RHCL_ZONE_ROOT_DOMAIN";

    private final Map<String, String> properties;

    public CorsOriginsConfigSource() {
        this.properties = computeProperties(System.getenv(ENV_VAR));
    }

    static Map<String, String> computeProperties(String zone) {
        if (zone == null || zone.isBlank()) {
            return Map.of();
        }
        String trimmed = zone.trim();
        // Quarkus accepts origins as Java regex wrapped in /.../. Inner slashes in http(s)://
        // MUST be escaped or the second '/' terminates the pattern early and every Origin fails CORS.
        String regex = "/https\\?:\\/\\/([a-zA-Z0-9-]+\\.)*\\Q" + trimmed + "\\E(:\\d+)?/";
        Map<String, String> props = new HashMap<>(1);
        props.put(PROPERTY, regex);
        return props;
    }

    @Override
    public Map<String, String> getProperties() {
        return properties;
    }

    @Override
    public Set<String> getPropertyNames() {
        return properties.keySet();
    }

    @Override
    public String getValue(String propertyName) {
        return properties.get(propertyName);
    }

    @Override
    public String getName() {
        return "RhclCorsOriginsConfigSource";
    }

    @Override
    public int getOrdinal() {
        // Higher than application.properties (250) so the override wins when set.
        return 280;
    }
}
