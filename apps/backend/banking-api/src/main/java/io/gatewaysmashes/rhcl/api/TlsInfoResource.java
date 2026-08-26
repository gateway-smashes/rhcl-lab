package io.gatewaysmashes.rhcl.api;

import io.vertx.ext.web.RoutingContext;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSession;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Exposes negotiated TLS parameters (version, cipher, ALPN, peer chain) so
 * RHCL labs can validate from the application side what the gateway negotiated
 * with the backend, including mTLS scenarios.
 *
 * Maps to RHCL requirements: 47 (backend TLS 1.2/1.3), 49 (backend mTLS),
 * 50 (cipher), 51 (OCSP visibility hooks), 52 (CRL hooks), 53 (leaf cert).
 *
 * Returns sensible empty values when called over plain HTTP so the endpoint
 * is also useful as a quick "is the request actually TLS?" probe.
 */
@Path("/api/tls/info")
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class TlsInfoResource {

    private static final Logger LOG = Logger.getLogger(TlsInfoResource.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @GET
    public Map<String, Object> info(@Context RoutingContext rc) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("instance", instanceName);
        response.put("timestamp", OffsetDateTime.now().toString());
        response.put("scheme", rc.request().scheme());
        response.put("isSSL", rc.request().isSSL());
        response.put("forwardedProto", rc.request().getHeader("x-forwarded-proto"));
        response.put("alpn", String.valueOf(rc.request().version()));

        SSLSession session = rc.request().sslSession();
        if (session == null) {
            response.put("tlsVersion", null);
            response.put("cipherSuite", null);
            response.put("peerCertificates", List.of());
            response.put("note", "Request was not TLS-terminated by this JVM "
                    + "(plain HTTP or TLS terminated upstream by the gateway).");
            return response;
        }

        response.put("tlsVersion", session.getProtocol());
        response.put("cipherSuite", session.getCipherSuite());
        response.put("sessionId", bytesToHex(session.getId()));

        List<Map<String, Object>> peers = new ArrayList<>();
        try {
            Certificate[] chain = session.getPeerCertificates();
            for (Certificate cert : chain) {
                if (!(cert instanceof X509Certificate x509)) {
                    continue;
                }
                Map<String, Object> certInfo = new LinkedHashMap<>();
                certInfo.put("subject", x509.getSubjectX500Principal().getName());
                certInfo.put("issuer", x509.getIssuerX500Principal().getName());
                certInfo.put("serial", x509.getSerialNumber().toString(16));
                certInfo.put("notBefore", x509.getNotBefore().toString());
                certInfo.put("notAfter", x509.getNotAfter().toString());
                certInfo.put("sigAlg", x509.getSigAlgName());
                certInfo.put("keyAlg", x509.getPublicKey().getAlgorithm());
                peers.add(certInfo);
            }
        } catch (SSLPeerUnverifiedException e) {
            response.put("clientAuth", "not-presented");
        }
        response.put("peerCertificates", peers);

        // Surface gateway-supplied client cert when mTLS terminates upstream.
        String xfcc = rc.request().getHeader("x-forwarded-client-cert");
        if (xfcc != null && !xfcc.isBlank()) {
            response.put("xForwardedClientCert", xfcc);
        }

        LOG.infof("tls info instance=%s tlsVersion=%s cipher=%s alpn=%s peers=%d",
                instanceName, session.getProtocol(), session.getCipherSuite(),
                rc.request().version(), peers.size());
        return response;
    }

    private static String bytesToHex(byte[] bytes) {
        if (bytes == null) return null;
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
}
