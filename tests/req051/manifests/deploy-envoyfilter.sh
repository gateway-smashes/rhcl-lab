#!/usr/bin/env bash
set -euo pipefail

# Generate and apply EnvoyFilter manifests referencing CA certs mounted
# from Secrets (via volume mounts on the gateway deployment).
#
# The CA files are available at:
#   /etc/certs/intermediate-ca/ca.crt  (from Secret req051-intermediate-ca-sdscert)
#   /etc/certs/root-ca/ca.crt          (from Secret req051-root-ca-sdscert)
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   cd tests/req051/manifests && ./deploy-envoyfilter.sh

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

generate_envoyfilter() {
  local NAME="$1"
  local SNI="$2"
  local CA_PATH="$3"

  python3 -c "
import json, sys

doc = {
    'apiVersion': 'networking.istio.io/v1alpha3',
    'kind': 'EnvoyFilter',
    'metadata': {
        'name': '$NAME',
        'namespace': 'req051-gateway',
        'labels': {
            'app.kubernetes.io/part-of': 'rhcl-req051-mtls',
            'rhcl-lab/requirement': 'req051-056-mtls',
        },
    },
    'spec': {
        'workloadSelector': {
            'labels': {
                'gateway.networking.k8s.io/gateway-name': 'req051-mtls-gateway',
            },
        },
        'configPatches': [{
            'applyTo': 'FILTER_CHAIN',
            'match': {
                'context': 'GATEWAY',
                'listener': {
                    'name': '0.0.0.0_443',
                    'filterChain': {
                        'sni': '$SNI',
                    },
                },
            },
            'patch': {
                'operation': 'MERGE',
                'value': {
                    'transport_socket': {
                        'name': 'envoy.transport_sockets.tls',
                        'typed_config': {
                            '@type': 'type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext',
                            'require_client_certificate': True,
                            'common_tls_context': {
                                'validation_context': {
                                    'trusted_ca': {
                                        'filename': '$CA_PATH',
                                    },
                                },
                            },
                        },
                    },
                },
            },
        }],
    },
}

json.dump(doc, sys.stdout, indent=2)
"
}

# EnvoyFilter for the ACCEPT_UNTRUSTED listener. trust_chain_verification=
# ACCEPT_UNTRUSTED makes the chain-trust check NON-fatal: any client cert that is
# presented is accepted, whether or not it chains to the trusted_ca. Only
# require_client_certificate still gates (a cert must be presented).
#
# NOTES (verified on OSSM Envoy 1.35, OpenSSL build):
#  - A trusted_ca is still MANDATORY — Envoy needs a trust store to attempt the
#    (now non-fatal) verification.
#  - ACCEPT_UNTRUSTED also disables SAN matching: match_typed_subject_alt_names
#    is NOT enforced here (a SAN mismatch is just another verification failure
#    that ACCEPT_UNTRUSTED permits). To gate by SAN, use VERIFY_TRUST_CHAIN.
generate_envoyfilter_untrusted() {
  local NAME="$1"
  local SNI="$2"

  python3 -c "
import json, sys

doc = {
    'apiVersion': 'networking.istio.io/v1alpha3',
    'kind': 'EnvoyFilter',
    'metadata': {
        'name': '$NAME',
        'namespace': 'req051-gateway',
        'labels': {
            'app.kubernetes.io/part-of': 'rhcl-req051-mtls',
            'rhcl-lab/requirement': 'req051-056-mtls',
        },
    },
    'spec': {
        'workloadSelector': {
            'labels': {
                'gateway.networking.k8s.io/gateway-name': 'req051-mtls-gateway',
            },
        },
        'configPatches': [{
            'applyTo': 'FILTER_CHAIN',
            'match': {
                'context': 'GATEWAY',
                'listener': {
                    'name': '0.0.0.0_443',
                    'filterChain': {'sni': '$SNI'},
                },
            },
            'patch': {
                'operation': 'MERGE',
                'value': {
                    'transport_socket': {
                        'name': 'envoy.transport_sockets.tls',
                        'typed_config': {
                            '@type': 'type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext',
                            'require_client_certificate': True,
                            'common_tls_context': {
                                'validation_context': {
                                    'trusted_ca': {
                                        'filename': '/etc/certs/intermediate-ca/ca.crt',
                                    },
                                    'trust_chain_verification': 'ACCEPT_UNTRUSTED',
                                },
                            },
                        },
                    },
                },
            },
        }],
    },
}

json.dump(doc, sys.stdout, indent=2)
"
}

# EnvoyFilter that forwards the client certificate to the backend via the
# x-forwarded-client-cert (XFCC) header. Patches the HTTP Connection Manager
# (shared by all SNI filter chains on 0.0.0.0_443), so it applies to every host
# on this gateway. Istio defaults the gateway to SANITIZE (strips XFCC); here we
# SANITIZE_SET and inject the full cert (PEM) plus subject/SAN.
generate_envoyfilter_xfcc() {
  python3 -c "
import json, sys

doc = {
    'apiVersion': 'networking.istio.io/v1alpha3',
    'kind': 'EnvoyFilter',
    'metadata': {
        'name': 'req051-xfcc',
        'namespace': 'req051-gateway',
        'labels': {
            'app.kubernetes.io/part-of': 'rhcl-req051-mtls',
            'rhcl-lab/requirement': 'req051-056-mtls',
        },
    },
    'spec': {
        'workloadSelector': {
            'labels': {
                'gateway.networking.k8s.io/gateway-name': 'req051-mtls-gateway',
            },
        },
        'configPatches': [{
            'applyTo': 'NETWORK_FILTER',
            'match': {
                'context': 'GATEWAY',
                'listener': {
                    'filterChain': {
                        'filter': {'name': 'envoy.filters.network.http_connection_manager'},
                    },
                },
            },
            'patch': {
                'operation': 'MERGE',
                'value': {
                    'typed_config': {
                        '@type': 'type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager',
                        'forward_client_cert_details': 'SANITIZE_SET',
                        'set_current_client_cert_details': {
                            'subject': True,
                            'cert': True,
                            'chain': True,
                            'dns': True,
                            'uri': True,
                        },
                    },
                },
            },
        }],
    },
}

json.dump(doc, sys.stdout, indent=2)
"
}

APPS_PREFIX="${RHCL_APPS_PREFIX:-.}"

echo "==> Deploying EnvoyFilter: req056-mtls-single-ca (Intermediate CA)..."
echo "    SNI: req056-mtls${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}"
generate_envoyfilter \
  "req056-mtls-single-ca" \
  "req056-mtls${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}" \
  "/etc/certs/intermediate-ca/ca.crt" | oc apply -f -

echo "==> Deploying EnvoyFilter: req051-mtls-chain-ca (Root CA)..."
echo "    SNI: req051-mtls${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}"
generate_envoyfilter \
  "req051-mtls-chain-ca" \
  "req051-mtls${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}" \
  "/etc/certs/root-ca/ca.crt" | oc apply -f -

echo "==> Deploying EnvoyFilter: req051-accept-untrusted (ACCEPT_UNTRUSTED)..."
echo "    SNI: req051-untrusted${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}"
generate_envoyfilter_untrusted \
  "req051-accept-untrusted" \
  "req051-untrusted${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}" | oc apply -f -

echo "==> Deploying EnvoyFilter: req051-xfcc (forward client cert to backend via XFCC)..."
generate_envoyfilter_xfcc | oc apply -f -

echo ""
echo "EnvoyFilters deployed (referencing mounted CA files)."
echo "Wait ~5s for Envoy to pick up changes."
