package io.gatewaysmashes.rhcl.api;

import io.gatewaysmashes.rhcl.grpc.Bank;
import io.gatewaysmashes.rhcl.grpc.BankingService;
import io.gatewaysmashes.rhcl.grpc.EchoMessage;
import io.gatewaysmashes.rhcl.grpc.HealthEvent;
import io.gatewaysmashes.rhcl.grpc.HealthRequest;
import io.gatewaysmashes.rhcl.grpc.SummaryRequest;
import io.gatewaysmashes.rhcl.grpc.SummaryResponse;
import io.quarkus.grpc.GrpcService;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * gRPC implementation of the banking API. Listens on the Quarkus gRPC server
 * (default port 9000, HTTP/2 cleartext). Reflection is enabled so
 * {@code grpcurl -plaintext localhost:9000 list} discovers this service.
 *
 * Maps to RHCL requirement 48 (gRPC backend) and supports the broader
 * "consume backends in HTTP/2" story (req 54).
 */
@GrpcService
public class BankingGrpcService implements BankingService {

    private static final Logger LOG = Logger.getLogger(BankingGrpcService.class);

    @ConfigProperty(name = "app.instance-name")
    String instanceName;

    @Inject
    BankingResource bankingResource;

    @Inject
    BackendModeHolder modeHolder;

    @Override
    public Uni<SummaryResponse> getSummary(SummaryRequest request) {
        String version = request.getApiVersion().isEmpty() ? "v1" : request.getApiVersion();
        Map<String, Object> snapshot = bankingResource.summarySnapshot(version);
        SummaryResponse.Builder builder = SummaryResponse.newBuilder()
                .setApiVersion(asString(snapshot.get("apiVersion")))
                .setInstance(asString(snapshot.get("instance")))
                .setBackendTag(asString(snapshot.get("backendTag")))
                .setTimestamp(asString(snapshot.get("timestamp")))
                .setInvestments(asString(snapshot.get("investments")))
                .setAccountTotal(asString(snapshot.get("accountTotal")))
                .setGrandTotal(asString(snapshot.get("grandTotal")));

        Object banks = snapshot.get("banks");
        if (banks instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Map<?, ?> bank) {
                    builder.addBanks(Bank.newBuilder()
                            .setBankName(asString(bank.get("bankName")))
                            .setAccount(asString(bank.get("account")))
                            .setBalance(asString(bank.get("balance")))
                            .build());
                }
            }
        }

        LOG.infof("grpc getSummary version=%s traceId=%s instance=%s",
                version, request.getTraceId(), instanceName);
        return Uni.createFrom().item(builder.build());
    }

    @Override
    public Multi<HealthEvent> streamHealth(HealthRequest request) {
        long interval = request.getIntervalMs() <= 0 ? 1000L : request.getIntervalMs();
        long max = request.getMaxEvents() <= 0 ? Long.MAX_VALUE : request.getMaxEvents();
        LOG.infof("grpc streamHealth instance=%s intervalMs=%d maxEvents=%d", instanceName, interval, max);

        return Multi.createFrom().ticks().every(Duration.ofMillis(interval))
                .select().first(max)
                .map(tick -> HealthEvent.newBuilder()
                        .setInstance(instanceName)
                        .setMode(modeHolder.getMode())
                        .setReady(modeHolder.isReady())
                        .setTimestamp(OffsetDateTime.now().toString())
                        .setSequence(tick)
                        .build());
    }

    @Override
    public Multi<EchoMessage> echoStream(Multi<EchoMessage> request) {
        AtomicLong seq = new AtomicLong();
        LOG.infof("grpc echoStream opened instance=%s", instanceName);
        return request.map(in -> EchoMessage.newBuilder()
                .setText(in.getText())
                .setClientSendEpochMs(in.getClientSendEpochMs())
                .setServerRecvEpochMs(Instant.now().toEpochMilli())
                .setInstance(instanceName)
                .setSequence(seq.incrementAndGet())
                .build());
    }

    private String asString(Object value) {
        return value == null ? "" : value.toString();
    }
}
