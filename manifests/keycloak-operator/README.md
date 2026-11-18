# Keycloak Operator resources

These definitions come from `keycloak/keycloak-k8s-resources` 26.8.2. The operator is scoped to the Keycloak namespace. Argo CD applies this Kustomize directory before deploying the Keycloak instance.

When updating `operators.keycloak-operator` in `versions.yaml`, use the matching upstream resource list. Include each CRD that the operator watches, including the OIDC and SAML client resources added in 26.8. A missing watched API prevents the operator from starting.

```bash
release=26.8.2
output=manifests/keycloak-operator
upstream="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$release/kubernetes"
curl -fsSL "$upstream/kustomization.yml" -o "$output/kustomization.yml"
while IFS= read -r resource; do
  curl -fsSL "$upstream/$resource" -o "$output/$resource" || break
done < <(yq -r '.resources[]' "$output/kustomization.yml")
```

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for license and modification details.
