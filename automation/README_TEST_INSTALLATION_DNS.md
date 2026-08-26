# DNS Provider Secret + DNSPolicy Test Installation

This guide validates the DNS provider secret **and** the optional DNSPolicy
created by `playbooks/dns-install.yml`.

> **Heads-up.** `playbooks/install-all.yml` imports `dns-install.yml`
> unconditionally, so the variables documented below (provider, namespace,
> credentials) are also required when running the all-in-one installer. The
> `assert_dns_inputs.yml` precondition will fail fast if they are missing.
> If you do not want a cloud DNS provider, run the playbooks individually and
> skip `dns-install.yml`.

## What the playbook creates

1. The DNS provider `Secret` (always).
2. A `DNSPolicy` targeting the apps Gateway (default: **on**, controlled by
   `RHCL_DNS_POLICY_ENABLED`). Without this policy, RHCL/Kuadrant will not
   program any DNS records for the hostnames declared in your `HTTPRoute`s,
   even if the Gateway and routes are healthy.

   This matches the official RHCL 1.3 deployment flow (section 1.2.3 of
   *Deploying Red Hat Connectivity Link*), which lists `DNSPolicy` as one of
   the policies a platform engineer must apply after the Gateway exists.
   The minimal `spec` we generate (`targetRef` + `providerRefs`) is the same
   shape shown in the docs; optional `loadBalancing` (geo/weight) and
   `healthCheck` blocks are commented in the template for easy extension.

> **Namespace constraint.** The `DNSPolicy` `targetRef` and `providerRefs`
> are local-namespace in Kuadrant 1.x. The Secret, the DNSPolicy and the
> target Gateway therefore must live in the **same namespace**. The default
> Gateway namespace in this repo is `openshift-ingress` — if you keep
> `RHCL_DNS_NAMESPACE=api-gateway` (the legacy default), the install playbook
> will fail fast with a clear message. Either align the namespaces, or set
> `RHCL_DNS_POLICY_ENABLED=false` to skip DNSPolicy creation.

## Preconditions

- `KUBECONFIG` points to the target cluster, or `oc login` already created a working context
- RHCL is already installed
- DNS credential variables were provided to the playbook
- The target Gateway already exists (or will be created shortly after — the
  DNSPolicy is admitted but stays `enforced=false` until its target appears)

## Run the playbook

Example with environment variables for AWS:

```bash
export RHCL_DNS_PROVIDER=aws
export RHCL_DNS_NAMESPACE=openshift-ingress     # must match the Gateway namespace
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_AWS_ACCESS_KEY_ID=AKIA...
export RHCL_DNS_AWS_SECRET_ACCESS_KEY=...
export RHCL_DNS_AWS_REGION=us-east-1

# DNSPolicy controls (all optional — defaults shown)
# export RHCL_DNS_POLICY_ENABLED=true
# export RHCL_DNS_POLICY_TARGET_GATEWAY_NAME=rhcl-apps-gateway
# export RHCL_DNS_POLICY_TARGET_GATEWAY_NAMESPACE=openshift-ingress
# export RHCL_DNS_POLICY_NAME=rhcl-apps-gateway-dns
```

Then run:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/dns-install.yml
```

## Use a custom DNS domain instead of the cluster's ingress domain

By default, hostnames in the apps Gateway and HTTPRoutes fall back to
`<route-name>.<cluster-ingress-domain>` (queried from the OpenShift `Ingress`
config). To anchor everything on a domain you control:

```bash
# Same role as ${KUADRANT_ZONE_ROOT_DOMAIN} in the upstream Kuadrant docs.
# Used as the suffix for any hostname not provided explicitly.
export RHCL_ZONE_ROOT_DOMAIN=example.com
# (KUADRANT_ZONE_ROOT_DOMAIN is also accepted for parity with the docs.)
```

This alone changes the default hostnames to e.g.
`banking-api-connectivity.example.com`, `mobile-bank-rhcl-apps.example.com`,
`mcp-gateway.example.com`. Per-route overrides (`APPS_CONNECTIVITY_ROUTE_HOSTNAME`,
`APPS_CONNECTIVITY_FRONTEND_ROUTE_HOSTNAME`, `MCP_GATEWAY_LISTENER_HOSTNAME`,
`MCP_GATEWAY_HOSTNAME`) still win when set.

### Allow arbitrary subdomains added later (wildcard listener)

The Gateway listeners normally pin to the exact route FQDNs the playbook
generates. That blocks `HTTPRoute`s applied **after** the Ansible run from
attaching to the Gateway with a different hostname (Gateway API rejects them
with `NoMatchingListenerHostname`). To accept any `<subdomain>.<root>` later:

```bash
export RHCL_ZONE_ROOT_DOMAIN=example.com
export APPS_CONNECTIVITY_LISTENER_WILDCARD_ENABLED=true
```

With wildcard mode on:

- The HTTP listener (port 80) is rendered as a single listener with
  `hostname: "*.example.com"` instead of one listener per route. The frontend
  HTTP listener block is omitted (the wildcard already covers it).
- If `APPS_CONNECTIVITY_TLS_ENABLED=true`, the HTTPS listener uses
  `*.example.com` as well — your cert-manager issuer must produce a wildcard
  certificate for that root (DNS-01 is required; HTTP-01 cannot issue
  wildcards).
- `RHCL_ZONE_ROOT_DOMAIN` becomes mandatory; the playbook fails fast otherwise.
- The DNS provider credentials still need write access to the `example.com`
  zone — the wildcard listener does not bypass that constraint.

For routes in a **different DNS zone** (e.g. `outrodominio.com.br`), wildcard
mode is not enough on its own: you'd also need a second listener for that
hostname pattern and DNS provider credentials with permission on that zone (or
a separate `Secret` + `DNSPolicy`).

## Azure: obtain and pass the credentials JSON

The Azure DNS provider expects an `azure.json` blob — the same format consumed by `external-dns` / `cert-manager` and based on a service principal that has DNS Zone Contributor permission on the target zone.

### 1. Create a service principal scoped to the DNS zone

Adjust the variables to match your Azure subscription, resource group and zone:

```bash
AZ_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
AZ_RESOURCE_GROUP="my-dns-rg"
AZ_DNS_ZONE="example.com"
AZ_SP_NAME="rhcl-dns-sp"

DNS_ZONE_ID="$(az network dns zone show \
  --name "${AZ_DNS_ZONE}" \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --query id -o tsv)"

az ad sp create-for-rbac \
  --name "${AZ_SP_NAME}" \
  --role "DNS Zone Contributor" \
  --scopes "${DNS_ZONE_ID}"
```

The command outputs `appId`, `password` and `tenant`. Keep them — `password` is shown only once.

### 2. Build the `azure.json` file

Create a file (for example `~/.azure/rhcl-dns.json`) with this shape:

```json
{
  "tenantId": "<tenant>",
  "subscriptionId": "<AZ_SUBSCRIPTION_ID>",
  "resourceGroup": "<AZ_RESOURCE_GROUP>",
  "aadClientId": "<appId>",
  "aadClientSecret": "<password>"
}
```

Mandatory keys are `tenantId`, `subscriptionId`, `resourceGroup`, `aadClientId` and `aadClientSecret`. Do not commit this file to git.

### 3. Pass it to the playbook

There are two mutually exclusive ways. Pick one:

**Option A — by file path (recommended):**

```bash
export RHCL_DNS_PROVIDER=azure
export RHCL_DNS_NAMESPACE=api-gateway
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_AZURE_JSON_FILE="${HOME}/.azure/rhcl-dns.json"
```

The role reads the file with `lookup('file', ...)` and stores it in the secret under the key `azure.json`.

**Option B — inline JSON string:**

```bash
export RHCL_DNS_PROVIDER=azure
export RHCL_DNS_NAMESPACE=api-gateway
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_AZURE_JSON="$(cat ${HOME}/.azure/rhcl-dns.json)"
```

Validation in [roles/common/tasks/assert_dns_inputs.yml](automation/roles/common/tasks/assert_dns_inputs.yml) requires at least one of `RHCL_DNS_AZURE_JSON` or `RHCL_DNS_AZURE_JSON_FILE`. If both are set, the inline value wins (see [roles/dns/templates/secret-azure.yml.j2](automation/roles/dns/templates/secret-azure.yml.j2)).

Then run the playbook:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/dns-install.yml
```

## GCP: obtain and pass the credentials JSON

The GCP DNS provider expects two values: the project id and a Google service account key JSON (`GOOGLE`). The service account must have permission to manage records in the target Cloud DNS zone (`roles/dns.admin`, or a tighter custom role scoped to the zone).

### 1. Create a service account with DNS permissions

Adjust the variables to match your GCP project:

```bash
GCP_PROJECT_ID="my-gcp-project"
GCP_SA_NAME="rhcl-dns-sa"
GCP_SA_EMAIL="${GCP_SA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${GCP_SA_NAME}" \
  --project "${GCP_PROJECT_ID}" \
  --display-name "RHCL DNS service account"

gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
  --member "serviceAccount:${GCP_SA_EMAIL}" \
  --role "roles/dns.admin"
```

### 2. Generate and download the key JSON

```bash
gcloud iam service-accounts keys create "${HOME}/.gcp/rhcl-dns.json" \
  --iam-account "${GCP_SA_EMAIL}"
```

The file looks like this:

```json
{
  "type": "service_account",
  "project_id": "<GCP_PROJECT_ID>",
  "private_key_id": "...",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "client_email": "<GCP_SA_EMAIL>",
  "client_id": "...",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "..."
}
```

Treat it as a secret. Do not commit this file to git.

### 3. Pass it to the playbook

`RHCL_DNS_GCP_PROJECT_ID` is always required. The key JSON can be supplied in two mutually exclusive ways:

**Option A — by file path (recommended):**

```bash
export RHCL_DNS_PROVIDER=gcp
export RHCL_DNS_NAMESPACE=api-gateway
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_GCP_PROJECT_ID="my-gcp-project"
export RHCL_DNS_GCP_GOOGLE_FILE="${HOME}/.gcp/rhcl-dns.json"
```

The role reads the file with `lookup('file', ...)` and stores it in the secret under the key `GOOGLE`.

**Option B — inline JSON string:**

```bash
export RHCL_DNS_PROVIDER=gcp
export RHCL_DNS_NAMESPACE=api-gateway
export RHCL_DNS_SECRET_NAME=rhcl-dns-credentials
export RHCL_DNS_GCP_PROJECT_ID="my-gcp-project"
export RHCL_DNS_GCP_GOOGLE="$(cat ${HOME}/.gcp/rhcl-dns.json)"
```

Validation in [roles/common/tasks/assert_dns_inputs.yml](automation/roles/common/tasks/assert_dns_inputs.yml) requires `RHCL_DNS_GCP_PROJECT_ID` plus at least one of `RHCL_DNS_GCP_GOOGLE` or `RHCL_DNS_GCP_GOOGLE_FILE`. If both are set, the inline value wins (see [roles/dns/templates/secret-gcp.yml.j2](automation/roles/dns/templates/secret-gcp.yml.j2)).

Then run the playbook:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/dns-install.yml
```

## Verify the secret

```bash
oc get secret -n api-gateway rhcl-dns-credentials
oc get secret -n api-gateway rhcl-dns-credentials -o yaml
```

Expected result:

- secret `rhcl-dns-credentials` exists in namespace `api-gateway`
- secret type matches the chosen provider:
  - `kuadrant.io/aws`
  - `kuadrant.io/azure`
  - `kuadrant.io/gcp`

## Provider-specific checks

For AWS:

```bash
oc get secret -n api-gateway rhcl-dns-credentials -o jsonpath='{.type}{"\n"}{.data.AWS_ACCESS_KEY_ID}{"\n"}{.data.AWS_SECRET_ACCESS_KEY}{"\n"}{.data.AWS_REGION}{"\n"}'
```

For Azure:

```bash
oc get secret -n api-gateway rhcl-dns-credentials -o jsonpath='{.type}{"\n"}{.data.azure\.json}{"\n"}'
```

For GCP:

```bash
oc get secret -n api-gateway rhcl-dns-credentials -o jsonpath='{.type}{"\n"}{.data.PROJECT_ID}{"\n"}{.data.GOOGLE}{"\n"}'
```

Expected result:

- required keys are present for the selected provider

## Verify the DNSPolicy

Skip this section if you ran with `RHCL_DNS_POLICY_ENABLED=false`.

```bash
oc get dnspolicy -n openshift-ingress
oc get dnspolicy -n openshift-ingress rhcl-apps-gateway-dns -o yaml
```

Expected result:

- a `DNSPolicy` named `<gateway-name>-dns` exists in the Gateway namespace
- `spec.targetRef` points to the apps Gateway
- `spec.providerRefs[0].name` matches `RHCL_DNS_SECRET_NAME`
- `status.conditions[type=Accepted].status == "True"`
- once an `HTTPRoute` is attached and its hostname falls within a zone the
  provider manages, `DNSRecord` resources start showing up:

  ```bash
  oc get dnsrecord -n openshift-ingress
  ```

The validate playbook automates the same checks:

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/dns-test.yml
```

## Cleanup

```bash
cd automation
ANSIBLE_LOCAL_TEMP=/private/tmp/ansible-local ansible-playbook playbooks/dns-remove.yml
```

`dns-remove.yml` deletes both the DNSPolicy and the provider Secret (idempotent
— missing resources are ignored).
