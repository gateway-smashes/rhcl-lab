package com.redhat.rhoai.assistant.inference;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.io.IOException;
import java.net.http.HttpClient;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.time.Duration;
import java.util.Collection;
import java.util.Optional;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

@ApplicationScoped
public class MaasHttpClientFactory {

    @ConfigProperty(name = "rhoai.maas.trust-store-path")
    Optional<String> trustStorePath;

    @ConfigProperty(name = "rhoai.maas.insecure-skip-verify", defaultValue = "false")
    boolean insecureSkipVerify;

    public HttpClient create(Duration connectTimeout) {
        HttpClient.Builder builder = HttpClient.newBuilder().connectTimeout(connectTimeout);
        sslContext().ifPresent(builder::sslContext);
        return builder.build();
    }

    private Optional<SSLContext> sslContext() {
        if (insecureSkipVerify) {
            try {
                SSLContext ctx = SSLContext.getInstance("TLS");
                ctx.init(null, new javax.net.ssl.TrustManager[]{
                        new javax.net.ssl.X509TrustManager() {
                            public void checkClientTrusted(java.security.cert.X509Certificate[] chain, String authType) {
                            }

                            public void checkServerTrusted(java.security.cert.X509Certificate[] chain, String authType) {
                            }

                            public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                                return new java.security.cert.X509Certificate[0];
                            }
                        }
                }, null);
                return Optional.of(ctx);
            } catch (Exception e) {
                throw new IllegalStateException("Failed to create permissive SSL context", e);
            }
        }

        String path = trustStorePath.orElse("").trim();
        if (path.isEmpty()) {
            return Optional.empty();
        }

        try {
            CertificateFactory factory = CertificateFactory.getInstance("X.509");
            Collection<? extends Certificate> certs;
            try (var in = Files.newInputStream(Path.of(path))) {
                certs = factory.generateCertificates(in);
            }
            KeyStore keyStore = KeyStore.getInstance(KeyStore.getDefaultType());
            keyStore.load(null, null);
            int index = 0;
            for (Certificate cert : certs) {
                keyStore.setCertificateEntry("ca-" + index++, cert);
            }
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            tmf.init(keyStore);
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, tmf.getTrustManagers(), null);
            return Optional.of(ctx);
        } catch (IOException e) {
            return Optional.empty();
        } catch (Exception e) {
            throw new IllegalStateException("Failed to load MAAS trust store from " + path, e);
        }
    }
}
