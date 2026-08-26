package com.redhat.rhoai.assistant.inference;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

@ApplicationScoped
public class MaasAuthTokenProvider {

    private static final Logger LOG = Logger.getLogger(MaasAuthTokenProvider.class);
    private static final String SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";

    @ConfigProperty(name = "rhoai.maas.api-key")
    String configuredApiKey;

    @ConfigProperty(name = "rhoai.maas.prefer-service-account-token", defaultValue = "true")
    boolean preferServiceAccountToken;

    public String bearerToken() {
        if (preferServiceAccountToken) {
            try {
                if (Files.exists(Path.of(SA_TOKEN_PATH))) {
                    String token = Files.readString(Path.of(SA_TOKEN_PATH), StandardCharsets.UTF_8).trim();
                    if (!token.isBlank()) {
                        return token;
                    }
                }
            } catch (IOException e) {
                LOG.debugf("Service account token unavailable: %s", e.getMessage());
            }
        }
        if (configuredApiKey == null || configuredApiKey.isBlank()) {
            throw new IllegalStateException("MAAS_API_KEY is not configured and no service account token is available");
        }
        return configuredApiKey;
    }
}
