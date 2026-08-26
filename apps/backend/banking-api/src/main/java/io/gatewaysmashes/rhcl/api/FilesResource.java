package io.gatewaysmashes.rhcl.api;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.core.StreamingOutput;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.OffsetDateTime;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

/**
 * File streaming endpoints for byte-flow / max-payload validation.
 *
 * Maps to RHCL requirements: 26 (byte streaming + max size), 34/35 (raw log
 * size limits when paired with WASM logging).
 */
@Path("/api/files")
@ApplicationScoped
public class FilesResource {

    private static final Logger LOG = Logger.getLogger(FilesResource.class);
    private static final int COPY_BUFFER = 64 * 1024;

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @ConfigProperty(name = "app.test-endpoints.enabled", defaultValue = "true")
    boolean enabled;

    private void ensureEnabled() {
        if (!enabled) {
            throw new NotFoundException();
        }
    }

    /**
     * Streams the request body, computes its size and SHA-256 without buffering
     * the full payload in memory. Honors the {@code quarkus.http.limits.max-body-size}
     * setting — anything larger is rejected by the HTTP layer before reaching here.
     */
    @POST
    @Path("/upload")
    @Consumes(MediaType.WILDCARD)
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, Object> upload(InputStream body,
                                       @HeaderParam("content-type") String contentType,
                                       @HeaderParam("x-flow-trace-id") String traceId) {
        ensureEnabled();
        long start = System.nanoTime();
        long total = 0;
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        byte[] buffer = new byte[COPY_BUFFER];
        try (InputStream in = body) {
            int read;
            while ((read = in.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
                total += read;
            }
        } catch (IOException e) {
            throw new RuntimeException("Failed to read request body", e);
        }
        long durationMs = (System.nanoTime() - start) / 1_000_000L;
        String sha = HexFormat.of().formatHex(digest.digest());

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("instance", instanceName);
        response.put("timestamp", OffsetDateTime.now().toString());
        response.put("traceId", traceId);
        response.put("contentType", contentType);
        response.put("bytesReceived", total);
        response.put("sha256", sha);
        response.put("durationMs", durationMs);

        LOG.infof("file upload instance=%s traceId=%s bytes=%d durationMs=%d sha256=%s contentType=%s",
                instanceName, traceId, total, durationMs, sha, contentType);
        return response;
    }

    /**
     * Streams pseudo-random bytes back to the client in fixed-size chunks.
     * Use {@code size} (bytes) and {@code chunkSize} (bytes) to drive download
     * behavior. Returns {@code Content-Length} so gateways can honor it.
     */
    @GET
    @Path("/download")
    @Produces(MediaType.APPLICATION_OCTET_STREAM)
    public Response download(@QueryParam("size") Long size,
                              @QueryParam("chunkSize") Integer chunkSize) {
        ensureEnabled();
        long total = size == null ? 1024L * 1024L : Math.max(0L, size);
        int chunk = chunkSize == null ? COPY_BUFFER : Math.max(1, chunkSize);

        StreamingOutput stream = output -> {
            byte[] buffer = new byte[chunk];
            long remaining = total;
            while (remaining > 0) {
                int toWrite = (int) Math.min(buffer.length, remaining);
                ThreadLocalRandom.current().nextBytes(buffer);
                output.write(buffer, 0, toWrite);
                remaining -= toWrite;
            }
            output.flush();
        };

        LOG.infof("file download instance=%s size=%d chunkSize=%d", instanceName, total, chunk);
        return Response.ok(stream)
                .header("content-length", String.valueOf(total))
                .header("x-test-instance", instanceName)
                .header("x-test-chunk-size", String.valueOf(chunk))
                .build();
    }
}
