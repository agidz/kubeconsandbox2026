# Third-party notices

The files listed below are distributed under the [Apache License 2.0](licenses/Apache-2.0.txt). The Apache license text applies to those third-party materials and their adaptations.

| Component | Upstream source | Files in this repository and local changes |
|---|---|---|
| Keycloak Operator Kubernetes resources | [Keycloak 26.8.2 resources](https://github.com/keycloak/keycloak-k8s-resources/tree/26.8.2/kubernetes) · [Upstream license](https://github.com/keycloak/keycloak-k8s-resources/blob/main/LICENSE.txt) | [Keycloak Operator YAML](manifests/keycloak-operator/) includes the upstream CRDs, controller resources, and Kustomize resource list. The YAML was reformatted for this repository. |
| Gateway API Inference Extension | [v1.6.2 release manifest](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.6.2/v1-manifests.yaml) · [Upstream license](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/LICENSE) | [Inference extension YAML](manifests/gateway-api-inference-extension/v1-manifests.yaml) is a reformatted version of the upstream release manifest. |
| kagent | [v1.0.0 PostgreSQL setup](https://github.com/kagent-dev/kagent/blob/v1.0.0/go/core/pkg/postgressetup/setup.sql) · [Upstream license](https://github.com/kagent-dev/kagent/blob/v1.0.0/LICENSE) | [10-kagent.sql](manifests/substrate-bootstrap/sql/10-kagent.sql) adapts the role and schema setup to CloudNativePG post-init and certificate-only login. Copyright 2017 Solo.io, Inc., as stated in the upstream license. |
| Agent Substrate | [v1.0.0 PostgreSQL setup](https://github.com/agent-substrate/substrate/blob/v1.0.0/pkg/postgressetup/setup.sql) · [Upstream license](https://github.com/agent-substrate/substrate/blob/v1.0.0/LICENSE) | [20-substrate.sql](manifests/substrate-bootstrap/sql/20-substrate.sql) adapts the role and schema setup to CloudNativePG post-init and certificate-only login. |

Deployment dependencies fetched separately, including images, charts, tools, and model weights, are distributed by their respective upstream projects under their own terms.
