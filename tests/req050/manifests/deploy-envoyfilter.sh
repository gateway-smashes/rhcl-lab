#!/usr/bin/env bash
set -euo pipefail

# Generate and apply the two EnvoyFilters that add revocation controls on top
# of the mTLS enforcement, per SNI/filter-chain.
#
# Files mounted on the gateway pod (see deploy.sh, volume mounts):
#   /etc/certs/intermediate-ca/ca.crt   ← Secret req050-intermediate-ca (mTLS trust anchor)
#   /etc/certs/crl/crl.pem              ← Secret req050-crl              (CRL listener)
#
# OCSP stapling is NOT done by overriding the cert here: Envoy rejects a filter
# chain that mixes an SDS-delivered cert (Istio's) with an inline one
# ("SDS and non-SDS TLS certificates may not be mixed"). Instead the OCSP staple
# rides in the SDS TLS secret under the key `tls.ocsp-staple` (see deploy.sh);
# Istio forwards it inline on the SDS cert. So the OCSP filter chain only needs
# the mTLS knobs (require_client_certificate + trusted_ca), same as the CRL one
# minus the CRL.
#
# Usage:
#   export RHCL_ZONE_ROOT_DOMAIN=mycluster.sandbox546.opentlc.com
#   cd tests/req050/manifests && ./deploy-envoyfilter.sh

: "${RHCL_ZONE_ROOT_DOMAIN:?Must set RHCL_ZONE_ROOT_DOMAIN}"

APPS_PREFIX="${RHCL_APPS_PREFIX:-.}"
NS="req050-gateway"
GW_NAME="req050-revocation-gateway"

# ---------------------------------------------------------------------------
# EnvoyFilter 1 — CRL revocation (SNI req050-crl.<domain>)
# ---------------------------------------------------------------------------
gen_crl_filter() {
  local SNI="$1"
  python3 -c "
import json, sys
doc = {
  'apiVersion': 'networking.istio.io/v1alpha3',
  'kind': 'EnvoyFilter',
  'metadata': {
    'name': 'req050-crl',
    'namespace': '$NS',
    'labels': {
      'app.kubernetes.io/part-of': 'rhcl-req050-revocation',
      'rhcl-lab/requirement': 'req050-ocsp-crl',
    },
  },
  'spec': {
    'workloadSelector': {'labels': {'gateway.networking.k8s.io/gateway-name': '$GW_NAME'}},
    'configPatches': [{
      'applyTo': 'FILTER_CHAIN',
      'match': {'context': 'GATEWAY', 'listener': {'name': '0.0.0.0_443', 'filterChain': {'sni': '$SNI'}}},
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
                  'trusted_ca': {'filename': '/etc/certs/intermediate-ca/ca.crt'},
                  'crl': {'filename': '/etc/certs/crl/crl.pem'},
                  'only_verify_leaf_cert_crl': True,
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

# ---------------------------------------------------------------------------
# EnvoyFilter 2 — OCSP stapling (SNI req050-ocsp.<domain>)
# Only enforces mTLS; the OCSP staple is delivered via the SDS secret
# (tls.ocsp-staple key), so no cert override here.
# ---------------------------------------------------------------------------
gen_ocsp_filter() {
  local SNI="$1"
  python3 -c "
import json, sys
doc = {
  'apiVersion': 'networking.istio.io/v1alpha3',
  'kind': 'EnvoyFilter',
  'metadata': {
    'name': 'req050-ocsp',
    'namespace': '$NS',
    'labels': {
      'app.kubernetes.io/part-of': 'rhcl-req050-revocation',
      'rhcl-lab/requirement': 'req050-ocsp-crl',
    },
  },
  'spec': {
    'workloadSelector': {'labels': {'gateway.networking.k8s.io/gateway-name': '$GW_NAME'}},
    'configPatches': [{
      'applyTo': 'FILTER_CHAIN',
      'match': {'context': 'GATEWAY', 'listener': {'name': '0.0.0.0_443', 'filterChain': {'sni': '$SNI'}}},
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
                  'trusted_ca': {'filename': '/etc/certs/intermediate-ca/ca.crt'},
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

echo "==> Deploying EnvoyFilter: req050-crl (CRL revocation)..."
echo "    SNI: req050-crl${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}"
gen_crl_filter "req050-crl${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}" | oc apply -f -

echo "==> Deploying EnvoyFilter: req050-ocsp (mTLS; staple via SDS tls.ocsp-staple)..."
echo "    SNI: req050-ocsp${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}"
gen_ocsp_filter "req050-ocsp${APPS_PREFIX}${RHCL_ZONE_ROOT_DOMAIN}" | oc apply -f -

echo ""
echo "EnvoyFilters deployed. Wait ~5s for Envoy to pick up changes."
