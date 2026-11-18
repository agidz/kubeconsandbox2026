# Module 4 — Route requests through Envoy

Gateway API separates the proxy implementation, listener configuration, and service routes. The GatewayClass chooses Envoy Gateway. The Gateway binds ports and certificate settings. HTTPRoute and TLSRoute connect hostnames and paths to Services. Envoy Gateway converts these objects to proxy configuration and uses SecurityPolicy for features such as OIDC and JWT verification.

Most web routes terminate TLS at the shared `sandbox` Gateway with a wildcard certificate. Harbor and OpenBao serve their own TLS certificates, so Envoy routes their encrypted traffic by SNI. Agent Router adds a separate Gateway for inference and MCP. Inspect `manifests/envoy-gateway/values.yaml` for route ports, backend namespaces, login policies, and timeouts.

## Lab 4.1 — Trace one route

```bash
kubectl get gatewayclass,gateway -A
kubectl -n monitoring get httproute jaeger -o yaml | yq '.spec'
kubectl -n monitoring get securitypolicy jaeger-sso -o yaml | yq '.spec.oidc | {clientID, scopes, redirectURL}'
kubectl -n harbor get tlsroute -o wide
```

Follow Jaeger's request from Envoy's TLS listener to Service port 16686. Compare the encrypted Harbor path.

## Lab 4.2 — Follow the OIDC redirect

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://jaeger.localtest.me/
```

Expect a 302 to Keycloak. In a browser, sign in as bob and inspect the cookies set for Jaeger. Bob can authenticate to the Inspector but receives 403 because its policy also requires `sandbox-admins`. Jaeger and Prometheus rely on gateway login. The kagent route forwards the access token to support delegation.

## Lab 4.3 — Resolve a service name inside a pod

```bash
kubectl run -it --rm dns --image=docker.io/library/busybox:1.37 --restart=Never -- nslookup keycloak.localtest.me
```

Outside the cluster the wildcard points to loopback. Inside, CoreDNS sends requests to the gateway Service, retaining the same hostname and TLS validation. Harbor has a direct internal rewrite for bootstrap and registry traffic. In kind, the host forwards 80 and 443 to NodePorts 30080 and 30443.

## Lab 4.4 — Identify the streaming routes

Find the routes with `timeout: 0s`. Explain why chat and MCP streams should survive Envoy's default 15-second request timeout. Use the route and policy objects to explain how authentication and authorization differ for bob's Inspector session. See [Agent Router](../adr/007-agent-router-over-agentgateway.md) and [Gateway API ownership](../adr/008-gateway-api-crds-owned-by-argo.md).
