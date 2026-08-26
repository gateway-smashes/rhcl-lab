#!/usr/bin/env python3
"""Discover or validate the public Route53 hosted zone for a given domain.

Two modes:

  discover_route53_zone.py <fqdn>
      Walks up the domain hierarchy, finds the publicly delegated zone whose
      DelegationSet.NameServers match the public NS records, prints the bare
      zone id. Exit 0 on success, 1 otherwise.

  discover_route53_zone.py --validate <zone_id> <fqdn>
      Asserts that <zone_id> is a public hosted zone in the active AWS
      account, whose Name covers <fqdn> (suffix match), and whose
      DelegationSet.NameServers match the public NS records for that zone's
      Name. Exit 0 on success; non-zero with a specific stderr explaining
      which check failed (creds, missing zone, wrong scope, NS mismatch).

Credentials are read from the standard AWS environment variables
(AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION) — no aws CLI
required.
"""

from __future__ import annotations

import subprocess
import sys


def public_ns(name: str) -> list[str]:
    try:
        out = subprocess.check_output(
            ["dig", "+short", "+time=5", "+tries=2", "NS", name], text=True
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    return sorted(line.rstrip(".").lower() for line in out.split("\n") if line.strip())


def route53_zones(client) -> list[dict]:
    zones = []
    paginator = client.get_paginator("list_hosted_zones")
    for page in paginator.paginate():
        for z in page["HostedZones"]:
            if not z.get("Config", {}).get("PrivateZone", False):
                zones.append(z)
    return zones


def route53_ns(client, zone_id: str) -> list[str]:
    resp = client.get_hosted_zone(Id=zone_id)
    ns = resp.get("DelegationSet", {}).get("NameServers", [])
    return sorted(s.rstrip(".").lower() for s in ns)


def discover(client, target: str) -> str | None:
    zones = route53_zones(client)
    parts = target.rstrip(".").split(".")
    for i in range(len(parts) - 1):
        candidate = ".".join(parts[i:])
        matches = [z for z in zones if z["Name"].rstrip(".") == candidate]
        if not matches:
            continue
        zone = matches[0]
        zone_id = zone["Id"].split("/")[-1]
        delegated_ns = route53_ns(client, zone_id)
        observed_ns = public_ns(candidate)
        if not observed_ns:
            continue
        if set(delegated_ns) == set(observed_ns):
            return zone_id
        print(
            f"[discover] zone {candidate} (id={zone_id}) is not the publicly "
            f"delegated zone (route53 NS={delegated_ns}, public NS={observed_ns}); "
            f"continuing search up the hierarchy",
            file=sys.stderr,
        )
    return None


# Exit codes for --validate (so callers can branch on the failure class).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_BOTO_MISSING = 3
EXIT_CREDS_BAD = 4         # AWS auth failed (InvalidClientTokenId / SignatureDoesNotMatch / ExpiredToken)
EXIT_ZONE_MISSING = 5      # zone id not found in this account
EXIT_ZONE_OUT_OF_SCOPE = 6 # zone Name does not cover the target fqdn
EXIT_ZONE_NS_MISMATCH = 7  # zone exists but is not the publicly delegated one
EXIT_ZONE_NOT_MOST_SPECIFIC = 8  # zone covers target but a more-specific delegated sub-zone exists


def validate(client, zone_id: str, target: str) -> int:
    """Check zone_id is a usable Route53 zone for target. Returns an EXIT_* code."""
    from botocore.exceptions import ClientError, NoCredentialsError, PartialCredentialsError  # type: ignore

    try:
        resp = client.get_hosted_zone(Id=zone_id)
    except (NoCredentialsError, PartialCredentialsError) as e:
        print(
            f"[validate] no usable AWS credentials in environment ({e}). Either "
            f"unset RHCL_DNS_AWS_ACCESS_KEY_ID/RHCL_DNS_AWS_SECRET_ACCESS_KEY in "
            f"~/cluster-secrets.sh so the role can auto-discover from "
            f"kube-system/aws-creds, or set them to valid values.",
            file=sys.stderr,
        )
        return EXIT_CREDS_BAD
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in {"InvalidClientTokenId", "SignatureDoesNotMatch", "ExpiredToken",
                    "AuthFailure", "UnrecognizedClientException"}:
            print(
                f"[validate] AWS credentials rejected (code={code}). The "
                f"RHCL_DNS_AWS_ACCESS_KEY_ID / RHCL_DNS_AWS_SECRET_ACCESS_KEY in "
                f"your shell are likely from a previous sandbox. Unset them and "
                f"re-source cluster-env.sh, or update ~/cluster-secrets.sh.",
                file=sys.stderr,
            )
            return EXIT_CREDS_BAD
        if code in {"NoSuchHostedZone", "HostedZoneNotFound"}:
            print(
                f"[validate] hosted zone {zone_id!r} does not exist in the active "
                f"AWS account. It probably belongs to a previous cluster — clear "
                f"LETSENCRYPT_AWS_HOSTED_ZONE_ID (or RHCL_DNS_AWS_ZONE_ID) from "
                f"~/cluster-secrets.sh and let the role auto-discover the right "
                f"one.",
                file=sys.stderr,
            )
            return EXIT_ZONE_MISSING
        print(f"[validate] AWS error fetching zone {zone_id}: {code or e}", file=sys.stderr)
        return EXIT_ZONE_MISSING

    zone_name = resp["HostedZone"]["Name"].rstrip(".").lower()
    target_norm = target.rstrip(".").lower()
    if not (target_norm == zone_name or target_norm.endswith("." + zone_name)):
        print(
            f"[validate] hosted zone {zone_id} has Name {zone_name!r} which does "
            f"NOT cover {target_norm!r}. The zone id is from a different cluster — "
            f"clear LETSENCRYPT_AWS_HOSTED_ZONE_ID from ~/cluster-secrets.sh.",
            file=sys.stderr,
        )
        return EXIT_ZONE_OUT_OF_SCOPE

    delegated_ns = sorted(
        s.rstrip(".").lower()
        for s in resp.get("DelegationSet", {}).get("NameServers", [])
    )
    observed_ns = public_ns(zone_name)
    if observed_ns and set(delegated_ns) != set(observed_ns):
        print(
            f"[validate] zone {zone_name} (id={zone_id}) is not the publicly "
            f"delegated zone (route53 NS={delegated_ns}, public NS={observed_ns}).",
            file=sys.stderr,
        )
        return EXIT_ZONE_NS_MISMATCH

    # Even when the supplied zone is a valid public parent, cert-manager will
    # create the ACME TXT record under that zone — but Let's Encrypt resolves
    # the challenge by walking NS delegations from the apex down to the target
    # FQDN. If a more-specific zone is delegated below this one and covers the
    # target, the TXT record never becomes visible to the ACME resolver and the
    # challenge stalls forever (real bug seen on RHPDS sandboxes where the apps
    # domain is a delegated sub-zone of the lab sandbox).
    most_specific = discover(client, target)
    if most_specific and most_specific != zone_id:
        print(
            f"[validate] hosted zone {zone_id} ({zone_name}) covers {target_norm!r} "
            f"but is NOT the most-specific publicly delegated zone — sub-zone "
            f"id={most_specific} is delegated below it and will intercept ACME "
            f"challenges for this FQDN. Clear LETSENCRYPT_AWS_HOSTED_ZONE_ID so "
            f"the role auto-discovers the right one, or set it to {most_specific}.",
            file=sys.stderr,
        )
        return EXIT_ZONE_NOT_MOST_SPECIFIC

    return EXIT_OK


def main() -> int:
    argv = sys.argv[1:]
    mode_validate = bool(argv) and argv[0] == "--validate"

    if mode_validate:
        if len(argv) != 3:
            print(
                "usage: discover_route53_zone.py --validate <zone_id> <fqdn>",
                file=sys.stderr,
            )
            return EXIT_USAGE
        zone_id, target = argv[1], argv[2]
    else:
        if len(argv) != 1:
            print(
                "usage: discover_route53_zone.py <fqdn>\n"
                "       discover_route53_zone.py --validate <zone_id> <fqdn>",
                file=sys.stderr,
            )
            return EXIT_USAGE
        target = argv[0]

    try:
        import boto3  # type: ignore
    except ImportError:
        print("boto3 is required: pip install boto3", file=sys.stderr)
        return EXIT_BOTO_MISSING

    client = boto3.client("route53")

    if mode_validate:
        return validate(client, zone_id, target)

    zone_id = discover(client, target)
    if zone_id is None:
        print(
            f"no publicly delegated Route53 hosted zone covers {target!r}",
            file=sys.stderr,
        )
        return 1
    print(zone_id)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
