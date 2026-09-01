package io.gatewaysmashes.rhcl.loadgen;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.quarkus.runtime.StartupEvent;
import io.quarkus.scheduler.Scheduled;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentSkipListMap;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.LongAdder;

/**
 * Continuous traffic engine. A {@link Scheduled} tick fires <code>rps</code>
 * requests per second at the configured target; a share of them (<code>errorRate</code>)
 * targets the banking-api error endpoint so a tunable slice of 5xx shows up on
 * the gateway dashboards, access logs and traces. Everything is adjustable at
 * runtime through {@link LoadGeneratorResource}.
 */
@ApplicationScoped
public class LoadGenerator {

    private static final Logger LOG = Logger.getLogger(LoadGenerator.class);

    /** One kind of request the generator can fire. Authenticated ones carry the api-key header. */
    public record RequestSpec(String method, String pathAndQuery, boolean authed, String label) {}

    /** Healthy baseline traffic (returns 2xx). */
    private static final List<RequestSpec> HEALTHY = List.of(
        new RequestSpec("GET", "/api/v1/accounts/summary", true,  "accounts-2xx"),
        new RequestSpec("GET", "/api/echo",                false, "echo-2xx")
    );
    /** Error traffic (returns 5xx). Weighted toward 500 (three of five entries). */
    private static final List<RequestSpec> ERRORS = List.of(
        new RequestSpec("GET", "/api/test/echo-error?status=500", true, "err-500"),
        new RequestSpec("GET", "/api/test/echo-error?status=500", true, "err-500"),
        new RequestSpec("GET", "/api/test/echo-error?status=500", true, "err-500"),
        new RequestSpec("GET", "/api/test/echo-error?status=503", true, "err-503"),
        new RequestSpec("GET", "/api/test/echo-error?status=502", true, "err-502")
    );

    @ConfigProperty(name = "loadgen.target-base-url", defaultValue = "")
    String targetBaseUrl;
    @ConfigProperty(name = "loadgen.api-key", defaultValue = "")
    String apiKey;
    @ConfigProperty(name = "loadgen.rps", defaultValue = "5")
    int initialRps;
    @ConfigProperty(name = "loadgen.error-rate", defaultValue = "0.8")
    double initialErrorRate;
    @ConfigProperty(name = "loadgen.autostart", defaultValue = "true")
    boolean autostart;
    @ConfigProperty(name = "loadgen.insecure-tls", defaultValue = "true")
    boolean insecureTls;
    @ConfigProperty(name = "loadgen.timeout-ms", defaultValue = "5000")
    int timeoutMs;
    @ConfigProperty(name = "loadgen.max-in-flight", defaultValue = "500")
    int maxInFlight;

    @Inject
    MeterRegistry registry;

    // Live, runtime-mutable knobs (adjusted via the REST control API).
    private final AtomicBoolean running = new AtomicBoolean(false);
    private final AtomicInteger rps = new AtomicInteger();
    private final AtomicReference<Double> errorRate = new AtomicReference<>(0.0);

    // Counters.
    private final LongAdder total = new LongAdder();       // completed (got an HTTP status)
    private final LongAdder failed = new LongAdder();       // connection/timeout errors (no status)
    private final LongAdder skipped = new LongAdder();      // dropped because max-in-flight was reached
    private final Map<Integer, LongAdder> byStatus = new ConcurrentSkipListMap<>();
    private volatile Instant startedAt;

    private HttpClient client;
    private Semaphore inFlight;

    void onStart(@Observes StartupEvent ev) {
        rps.set(Math.max(0, initialRps));
        errorRate.set(clamp(initialErrorRate));
        inFlight = new Semaphore(Math.max(1, maxInFlight));
        if (insecureTls) {
            // The JDK HttpClient honours this only when set before the client is built.
            System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
        }
        client = buildClient();
        LOG.infof("load-generator ready: target=%s rps=%d errorRate=%.2f autostart=%b insecureTls=%b",
            targetBaseUrl.isBlank() ? "(unset)" : targetBaseUrl, rps.get(), errorRate.get(), autostart, insecureTls);
        if (autostart) {
            if (targetBaseUrl.isBlank()) {
                LOG.warn("loadgen.autostart=true but loadgen.target-base-url is empty — staying idle. Set LOADGEN_TARGET_BASE_URL.");
            } else {
                start();
            }
        }
    }

    /** Fires up to <code>rps</code> requests every second while running. */
    @Scheduled(every = "1s")
    void tick() {
        if (!running.get() || client == null || targetBaseUrl.isBlank()) {
            return;
        }
        int n = rps.get();
        double er = errorRate.get();
        for (int i = 0; i < n; i++) {
            fireOne(er);
        }
    }

    private void fireOne(double er) {
        if (!inFlight.tryAcquire()) {
            skipped.increment();
            return;
        }
        RequestSpec spec = pick(er);
        HttpRequest req = build(spec);
        client.sendAsync(req, HttpResponse.BodyHandlers.discarding())
            .whenComplete((resp, err) -> {
                try {
                    if (err != null) {
                        failed.increment();
                        registry.counter("loadgen.requests", "outcome", "error").increment();
                    } else {
                        int code = resp.statusCode();
                        total.increment();
                        byStatus.computeIfAbsent(code, k -> new LongAdder()).increment();
                        registry.counter("loadgen.requests", "status_class", (code / 100) + "xx").increment();
                    }
                } finally {
                    inFlight.release();
                }
            });
    }

    private RequestSpec pick(double er) {
        var rnd = ThreadLocalRandom.current();
        List<RequestSpec> pool = (rnd.nextDouble() < er) ? ERRORS : HEALTHY;
        return pool.get(rnd.nextInt(pool.size()));
    }

    private HttpRequest build(RequestSpec spec) {
        HttpRequest.Builder b = HttpRequest.newBuilder()
            .uri(URI.create(base() + spec.pathAndQuery()))
            .timeout(Duration.ofMillis(timeoutMs))
            .header("x-flow-trace-id", "loadgen-" + UUID.randomUUID())
            .method(spec.method(), HttpRequest.BodyPublishers.noBody());
        if (spec.authed() && !apiKey.isBlank()) {
            b.header("api-key", apiKey);
        }
        return b.build();
    }

    private HttpClient buildClient() {
        HttpClient.Builder b = HttpClient.newBuilder()
            .connectTimeout(Duration.ofMillis(timeoutMs))
            .executor(Executors.newVirtualThreadPerTaskExecutor());
        if (insecureTls) {
            b.sslContext(trustAllContext());
        }
        return b.build();
    }

    private static SSLContext trustAllContext() {
        try {
            TrustManager[] trustAll = { new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] c, String a) {}
                public void checkServerTrusted(X509Certificate[] c, String a) {}
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }};
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, trustAll, new SecureRandom());
            return ctx;
        } catch (Exception e) {
            throw new IllegalStateException("cannot build insecure TLS context", e);
        }
    }

    private String base() {
        return targetBaseUrl.endsWith("/") ? targetBaseUrl.substring(0, targetBaseUrl.length() - 1) : targetBaseUrl;
    }

    private static double clamp(double v) {
        return Math.max(0.0, Math.min(1.0, v));
    }

    // --- control surface (called by the REST resource) ---

    public void start() {
        if (targetBaseUrl.isBlank()) {
            throw new IllegalStateException("no target: set LOADGEN_TARGET_BASE_URL first");
        }
        if (running.compareAndSet(false, true)) {
            startedAt = Instant.now();
            LOG.infof("load-generator START — target=%s rps=%d errorRate=%.2f", base(), rps.get(), errorRate.get());
        }
    }

    public void stop() {
        if (running.compareAndSet(true, false)) {
            LOG.info("load-generator STOP");
        }
    }

    public void reset() {
        total.reset();
        failed.reset();
        skipped.reset();
        byStatus.clear();
        startedAt = running.get() ? Instant.now() : null;
    }

    public void setRps(int v) {
        rps.set(Math.max(0, v));
    }

    public void setErrorRate(double v) {
        errorRate.set(clamp(v));
    }

    public Map<String, Object> config() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("targetBaseUrl", targetBaseUrl.isBlank() ? null : base());
        m.put("apiKeyPresent", !apiKey.isBlank());
        m.put("rps", rps.get());
        m.put("errorRate", errorRate.get());
        m.put("insecureTls", insecureTls);
        m.put("timeoutMs", timeoutMs);
        m.put("maxInFlight", maxInFlight);
        return m;
    }

    public Map<String, Object> snapshot() {
        Map<String, Integer> codes = new LinkedHashMap<>();
        long fivexx = 0, total5denom = 0;
        for (var e : byStatus.entrySet()) {
            int c = e.getValue().intValue();
            codes.put(String.valueOf(e.getKey()), c);
            total5denom += c;
            if (e.getKey() >= 500) fivexx += c;
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("running", running.get());
        m.put("uptimeSeconds", startedAt == null ? 0 : Duration.between(startedAt, Instant.now()).toSeconds());
        m.put("rps", rps.get());
        m.put("errorRate", errorRate.get());
        m.put("totalCompleted", total.sum());
        m.put("failed", failed.sum());
        m.put("skipped", skipped.sum());
        m.put("byStatus", codes);
        m.put("observedErrorRate", total5denom == 0 ? 0.0 : (double) fivexx / total5denom);
        m.put("target", targetBaseUrl.isBlank() ? null : base());
        return m;
    }
}
