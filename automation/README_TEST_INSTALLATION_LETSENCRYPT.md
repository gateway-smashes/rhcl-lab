# Let's Encrypt ClusterIssuer Test Installation

This guide validates the Let's Encrypt `ClusterIssuer` resources installed by `playbooks/letsencrypt-install.yml`.

## What it creates

- An `Opaque` secret in the cert-manager namespace holding the DNS-01 solver credentials
- A staging `ClusterIssuer` (`letsencrypt-staging`) — always
- A production `ClusterIssuer` (`letsencrypt-prod`) — only when `LETSENCRYPT_PROD_ENABLED=true`

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- `cert_manager` playbook already ran successfully and the cert-manager controller is running in the `cert-manager` namespace
- DNS provider credentials are available — same env vars used by `dns-install.yml`
- The DNS provider is authoritative for the hostnames you intend to certify (Let's Encrypt must be able to validate via DNS-01)
- For AWS auto-discovery: `aws` CLI and `dig` available on the control host

## Why cert-manager is patched with public DNS resolvers

The `cert_manager` role configures the controller with
`--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53` and
`--dns01-recursive-nameservers-only`. This is required when the cluster's
internal DNS leaks into a Route53 private hosted zone — without it, the ACME
propagation check follows the in-cluster resolver to a private NS that public
ACME servers cannot reach, and the challenge stays `pending` forever.

Tunable via `CERT_MANAGER_DNS01_RECURSIVE_NAMESERVERS` and
`CERT_MANAGER_DNS01_RECURSIVE_NAMESERVERS_ONLY`.

## Required input

- `LETSENCRYPT_EMAIL` — ACME contact address; Let's Encrypt sends expiration warnings here

## Solver-specific input

The solver reuses `RHCL_DNS_PROVIDER` by default. Override with `LETSENCRYPT_DNS_PROVIDER` if needed.

### AWS Route53

```bash
export LETSENCRYPT_EMAIL=admin@example.com
export RHCL_DNS_PROVIDER=aws
export RHCL_DNS_AWS_ACCESS_KEY_ID=AKIA...
export RHCL_DNS_AWS_SECRET_ACCESS_KEY=...
export RHCL_DNS_AWS_REGION=us-east-1
# optional: pin a specific hosted zone (skips auto-discovery)
export LETSENCRYPT_AWS_HOSTED_ZONE_ID=Z123ABC
```

When `LETSENCRYPT_AWS_HOSTED_ZONE_ID` is not set, the playbook auto-discovers the
public Route53 hosted zone that covers the **gateway connectivity FQDN**
(`<APPS_CONNECTIVITY_ROUTE_NAME>.<apps-domain>`, default
`banking-api-connectivity.<apps-domain>`). It walks up the FQDN one label at a
time (`banking-api-connectivity.apps.<cluster>` → `apps.<cluster>` → … → apex)
and selects the zone whose Route53 `DelegationSet.NameServers` match the NS
records actually returned by public DNS. Using the gateway FQDN instead of the
apps domain matters on RHPDS sandboxes where the cluster sits behind several
delegated zones — the longer FQDN lets the matcher land on the most-specific
delegated sub-zone (the one that actually receives ACME challenge traffic).
Orphan or private zones with overlapping names are skipped automatically.
Requires `boto3` and `dig` on the control host.

When you DO set `LETSENCRYPT_AWS_HOSTED_ZONE_ID` explicitly, the role validates
that it's the most-specific delegated zone for the gateway FQDN. If a
more-specific sub-zone is delegated below it, the role aborts with the id of
the zone you should use instead — that's the bug behind the `Ready=False`
forever scenarios on RHPDS where the sandbox parent (`sandbox<n>.opentlc.com`)
was supplied but the apps sub-zone (`<cluster>.<id>.sandbox<n>.opentlc.com`)
is the one that intercepts ACME challenges.

### Azure DNS

```bash
export LETSENCRYPT_EMAIL=admin@example.com
export RHCL_DNS_PROVIDER=azure
export RHCL_DNS_AZURE_JSON_FILE="${HOME}/.azure/rhcl-dns.json"
# required: the DNS zone name in Azure (for example example.com)
export LETSENCRYPT_AZURE_HOSTED_ZONE_NAME=example.com
```

If you already followed the DNS install guide and have `AZ_DNS_ZONE` exported in
the same shell, the role falls back to it when `LETSENCRYPT_AZURE_HOSTED_ZONE_NAME`
is not set, so you can skip the second export.

The role parses `azure.json` and injects `aadClientId`, `subscriptionId`, `tenantId`, and `resourceGroup` into the `ClusterIssuer`. Only `aadClientSecret` is stored in the solver secret.

### GCP CloudDNS

```bash
export LETSENCRYPT_EMAIL=admin@example.com
export RHCL_DNS_PROVIDER=gcp
export RHCL_DNS_GCP_PROJECT_ID=my-gcp-project
export RHCL_DNS_GCP_GOOGLE_FILE="${HOME}/.gcp/rhcl-dns.json"
```

## Run the playbook

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/letsencrypt-install.yml
```

To also create the production issuer:

```bash
export LETSENCRYPT_PROD_ENABLED=true
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/letsencrypt-install.yml
```

Production has stricter rate limits than staging. Validate everything against staging first.

## Verify

```bash
oc get secret -n cert-manager letsencrypt-dns-credentials
oc get clusterissuer letsencrypt-staging
oc get clusterissuer letsencrypt-staging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected result:

- secret `letsencrypt-dns-credentials` exists in namespace `cert-manager`
- `ClusterIssuer letsencrypt-staging` is `Ready=True`
- `ClusterIssuer letsencrypt-prod` is `Ready=True` only when `LETSENCRYPT_PROD_ENABLED=true`

## Use it from the apps connectivity gateway

Wire the issuer into the apps `TLSPolicy` flow:

```bash
export APPS_CONNECTIVITY_TLS_ENABLED=true
export APPS_CONNECTIVITY_TLS_ISSUER_NAME=letsencrypt-staging
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/apps-install.yml
```

See [README_TEST_INSTALLATION_APPS.md](/Users/lucianoscorsin/Repositorios/RedHat/rhcl-lab/automation/README_TEST_INSTALLATION_APPS.md) for the HTTPS verification steps.

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/letsencrypt-remove.yml
```

This removes both ClusterIssuers and the solver secret. Account private key secrets (`<issuer>-account-key`) are left in `cert-manager` and can be deleted manually if needed.
