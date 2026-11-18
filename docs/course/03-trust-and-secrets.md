# Module 3 — Follow trust and credentials

TLS trust starts with the local root CA created by `20-ca`. cert-manager's `sandbox-ca` ClusterIssuer uses it to sign service certificates, including the gateway wildcard. OpenBao PKI uses the same root to sign the SPIRE CA.

Follow [ADR-015](../adr/015-workload-identity-for-secrets.md) when providing credentials. First use the identity the platform already issues, such as an SVID or Pod Certificate. If the consumer requires a credential, let the workload fetch it from OpenBao at runtime. Use ESO to provision a Kubernetes Secret when the consumer only supports that interface. Keep generated credentials out of Git.

OpenBao storage starts sealed. The sandbox mounts the static key through a Secret so restarts can proceed without an operator, which puts the key under the same administrative boundary as the data. Bootstrap uses root credentials to initialize the service, revokes them, and uses a 15-minute `sandbox-operator` token for subsequent work. The Kubernetes auth backend validates ServiceAccount tokens and assigns policies.

## Lab 3.1 — Inspect the certificate chain

```bash
eval "$(scripts/ca-env.sh)"
openssl s_client -connect grafana.localtest.me:443 -servername grafana.localtest.me </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -dates
openssl x509 -in .state/ca/sandbox-root-ca.crt -noout -subject -ext basicConstraints
kubectl -n envoy-gateway-system get certificate
```

Match the wildcard issuer to the sandbox root. Note the root's `pathlen:1`, which constrains the number of intermediate CAs.

## Lab 3.2 — Trace the Grafana admin credential

```bash
kubectl -n monitoring get externalsecret grafana-admin -o yaml | yq '.spec'
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.metadata.labels}'
```

ESO reads `adminPassword` from `secret/platform/grafana` using the ClusterSecretStore `openbao`. In the OpenBao UI, choose OIDC and role `sandbox`. Compare browsing `secret/platform/` as admin and as bob.

## Lab 3.3 — Compare permissions

```bash
source scripts/lib/common.sh
bao_connect
bao_api GET sys/auth | jq -r '.data | keys[]'
bao_api GET sys/policies/acl/external-secrets | jq -r .data.policy
bao_api GET auth/token/lookup-self | jq '.data | {display_name, policies, ttl}'
```

Find Kubernetes, OIDC, and SPIFFE JWT login methods. Notice the ESO policy exclusion for `secret/bootstrap/*`, which includes the CA key.

## Lab 3.4 — Inventory Kubernetes Secrets

```bash
kubectl get secrets -A --no-headers | wc -l
kubectl get externalsecrets -A
```

Choose two synchronized secrets and explain what upstream feature would let each consumer use direct identity. Explain how a cluster administrator's access affects the static seal design. See the [trust map](../trust-map.md) and [OpenBao decision](../adr/005-openbao-static-auto-unseal.md).
