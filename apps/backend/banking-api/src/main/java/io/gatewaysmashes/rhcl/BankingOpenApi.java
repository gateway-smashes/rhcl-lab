package io.gatewaysmashes.rhcl;

import org.eclipse.microprofile.openapi.annotations.OpenAPIDefinition;
import org.eclipse.microprofile.openapi.annotations.info.Contact;
import org.eclipse.microprofile.openapi.annotations.info.Info;
import org.eclipse.microprofile.openapi.annotations.info.License;
import org.eclipse.microprofile.openapi.annotations.servers.Server;
import org.eclipse.microprofile.openapi.annotations.tags.Tag;

import jakarta.ws.rs.ApplicationPath;
import jakarta.ws.rs.core.Application;

/**
 * OpenAPI document metadata for the Banking API. Exposed at {@code /q/openapi}
 * (JSON/YAML) and {@code /q/swagger-ui}, and referenced by the RHCL
 * {@code APIProduct.spec.documentation} so the spec is validatable from both the
 * Developer Portal and the custom RHCL console plugin.
 */
@ApplicationPath("/")
@OpenAPIDefinition(
        info = @Info(
                title = "Banking API",
                version = "v1",
                description = "Sample banking API exposed through Red Hat Connectivity Link (RHCL / Kuadrant) "
                        + "for the RHCL PoC. Protected endpoints require an API key in the "
                        + "`api-key` header (issued via the Developer Portal); `/api/echo` and `/api/lb-test` "
                        + "are public.",
                contact = @Contact(name = "RHCL PoC Team", email = "rhcl-poc@example.com"),
                license = @License(name = "Apache 2.0", url = "https://www.apache.org/licenses/LICENSE-2.0")),
        servers = {
                @Server(url = "https://banking-api-connectivity.apps.cluster-7cpkl.7cpkl.sandbox5518.opentlc.com",
                        description = "RHCL gateway (api-key enforced)"),
                @Server(url = "/", description = "Direct service (bypasses the gateway)")
        },
        tags = {
                @Tag(name = "accounts", description = "Account summary, balances and transfers"),
                @Tag(name = "diagnostics", description = "Echo, TLS info and chaos/test endpoints"),
                @Tag(name = "ai", description = "OpenAI-compatible mock endpoints")
        })
public class BankingOpenApi extends Application {
}
