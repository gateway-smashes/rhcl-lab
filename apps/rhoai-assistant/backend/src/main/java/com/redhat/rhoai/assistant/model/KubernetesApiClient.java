package com.redhat.rhoai.assistant.model;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
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
public class KubernetesApiClient {

  private static final String SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";
  private static final String SA_NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
  private static final String SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";

  @ConfigProperty(name = "rhoai.kubernetes.api-server")
  Optional<String> apiServerOverride;

  @Inject
  ObjectMapper objectMapper;

  private volatile HttpClient httpClient;

  public JsonNode listCustomResources(String apiGroup, String version, String namespace, String plural)
      throws IOException, InterruptedException {
    String apiServer = resolveApiServer();
    String url = apiServer + "/apis/" + apiGroup + "/" + version + "/namespaces/" + namespace + "/" + plural;
    HttpRequest request = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .timeout(Duration.ofSeconds(15))
        .header("Authorization", "Bearer " + readServiceAccountToken())
        .header("Accept", "application/json")
        .GET()
        .build();

    HttpResponse<String> response = client().send(request, HttpResponse.BodyHandlers.ofString());
    if (response.statusCode() != 200) {
      throw new IOException("Kubernetes API " + url + " returned HTTP " + response.statusCode()
          + ": " + response.body());
    }
    return objectMapper.readTree(response.body());
  }

  private HttpClient client() {
    HttpClient existing = httpClient;
    if (existing != null) {
      return existing;
    }
    synchronized (this) {
      if (httpClient == null) {
        HttpClient.Builder builder = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10));
        sslContextFromFile(SA_CA_PATH).ifPresent(builder::sslContext);
        httpClient = builder.build();
      }
      return httpClient;
    }
  }

  private String resolveApiServer() {
    if (apiServerOverride.isPresent() && !apiServerOverride.get().isBlank()) {
      return trimTrailingSlash(apiServerOverride.get());
    }
    String host = System.getenv("KUBERNETES_SERVICE_HOST");
    String port = System.getenv("KUBERNETES_SERVICE_PORT");
    if (host == null || port == null) {
      throw new IllegalStateException("Not running in-cluster and rhoai.kubernetes.api-server is not set");
    }
    return "https://" + host + ":" + port;
  }

  public Optional<String> currentNamespace() {
    try {
      if (!Files.exists(Path.of(SA_NAMESPACE_PATH))) {
        return Optional.empty();
      }
      return Optional.of(Files.readString(Path.of(SA_NAMESPACE_PATH), StandardCharsets.UTF_8).trim());
    } catch (IOException e) {
      return Optional.empty();
    }
  }

  private static String readServiceAccountToken() throws IOException {
    if (!Files.exists(Path.of(SA_TOKEN_PATH))) {
      throw new IOException("Service account token not found at " + SA_TOKEN_PATH);
    }
    return Files.readString(Path.of(SA_TOKEN_PATH), StandardCharsets.UTF_8).trim();
  }

  private static Optional<SSLContext> sslContextFromFile(String path) {
    if (path == null || path.isBlank() || !Files.exists(Path.of(path))) {
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
    } catch (Exception e) {
      throw new IllegalStateException("Failed to load trust store from " + path, e);
    }
  }

  private static String trimTrailingSlash(String value) {
    return value.endsWith("/") ? value.substring(0, value.length() - 1) : value;
  }
}
