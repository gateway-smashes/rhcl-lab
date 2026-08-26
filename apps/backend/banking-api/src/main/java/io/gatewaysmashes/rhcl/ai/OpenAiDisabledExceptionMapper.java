package io.gatewaysmashes.rhcl.ai;

import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ExceptionMapper;
import jakarta.ws.rs.ext.Provider;

import java.util.Map;

@Provider
public class OpenAiDisabledExceptionMapper implements ExceptionMapper<OpenAiDisabledException> {

    @Override
    public Response toResponse(OpenAiDisabledException exception) {
        return Response.status(503)
                .type(MediaType.APPLICATION_JSON)
                .entity(Map.of(
                        "error", exception.getMessage(),
                        "mode", "disabled"))
                .build();
    }
}
