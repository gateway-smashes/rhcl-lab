package io.gatewaysmashes.rhcl.loadgen;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.Map;

/**
 * Control surface for the {@link LoadGenerator}. Everything the container needs
 * to start with is configured via env vars; these endpoints let you watch and
 * retune the running generator without a redeploy.
 */
@Path("/loadgen")
@Produces(MediaType.APPLICATION_JSON)
public class LoadGeneratorResource {

    @Inject
    LoadGenerator gen;

    /** Live counters: running state, total sent, per-status-code breakdown, observed 5xx share. */
    @GET
    @Path("/stats")
    public Map<String, Object> stats() {
        return gen.snapshot();
    }

    /** Current configuration (target, rps, errorRate, ...). */
    @GET
    @Path("/config")
    public Map<String, Object> config() {
        return gen.config();
    }

    /** Begin firing (fails with 409 if no target URL is configured). */
    @POST
    @Path("/start")
    public Response start() {
        try {
            gen.start();
            return Response.ok(gen.snapshot()).build();
        } catch (IllegalStateException e) {
            return Response.status(Response.Status.CONFLICT)
                .entity(Map.of("error", e.getMessage())).build();
        }
    }

    /** Stop firing (counters are kept). */
    @POST
    @Path("/stop")
    public Map<String, Object> stop() {
        gen.stop();
        return gen.snapshot();
    }

    /** Zero the counters. */
    @POST
    @Path("/reset")
    public Map<String, Object> reset() {
        gen.reset();
        return gen.snapshot();
    }

    /**
     * Retune at runtime, e.g. {@code POST /loadgen/config?rps=20&errorRate=0.5}.
     * Omitted params are left unchanged.
     */
    @POST
    @Path("/config")
    public Map<String, Object> tune(@QueryParam("rps") Integer rps,
                                    @QueryParam("errorRate") Double errorRate) {
        if (rps != null) {
            gen.setRps(rps);
        }
        if (errorRate != null) {
            gen.setErrorRate(errorRate);
        }
        return gen.config();
    }
}
