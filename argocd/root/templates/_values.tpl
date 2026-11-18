{{- define "kcs.issuer" -}}
{{ printf "https://keycloak.%s/realms/sandbox" .Values.baseDomain }}
{{- end -}}

{{- define "kcs.values.argocd" -}}
configs:
  cm:
    url: {{ printf "https://argocd.%s" .Values.baseDomain }}
    {{- with .Values.sandboxCA }}
    {{- $lines := list "name: Keycloak"
      (printf "issuer: %s" (include "kcs.issuer" $))
      "clientID: argocd"
      "clientSecret: $argocd-oidc:clientSecret"
      "requestedScopes: [openid, profile, email]"
      "rootCA: |"
      (indent 2 .) }}
    oidc.config: {{ join "\n" $lines | quote }}
    {{- end }}
{{- end -}}

{{- define "kcs.values.gitea" -}}
{{- $hostname := printf "git.%s" .Values.baseDomain -}}
gitea:
  config:
    server:
      DOMAIN: {{ $hostname }}
      ROOT_URL: {{ printf "https://%s/" $hostname }}
{{- end -}}

{{- define "kcs.values.grafana" -}}
{{- $protocol := printf "%s/protocol/openid-connect" (include "kcs.issuer" .) -}}
{{- $hostname := printf "grafana.%s" .Values.baseDomain -}}
grafana.ini:
  auth.generic_oauth:
    api_url: {{ printf "%s/userinfo" $protocol }}
    auth_url: {{ printf "%s/auth" $protocol }}
    token_url: {{ printf "%s/token" $protocol }}
    signout_redirect_url: {{ printf "%s/logout?post_logout_redirect_uri=https%%3A%%2F%%2F%s%%2Flogin" $protocol $hostname }}
  server:
    root_url: {{ printf "https://%s" $hostname }}
{{- end -}}

{{- define "kcs.values.spire" -}}
global:
  spire:
    jwtIssuer: {{ printf "https://oidc-discovery.%s" .Values.baseDomain }}
{{- end -}}

{{- define "kcs.values.kagent" -}}
substrateWorkerPool:
  workerImage: {{ get .Values.images "substrate-worker" }}
{{- end -}}

{{- define "kcs.values.substrate" -}}
images:
  agentgateway: {{ get .Values.images "agentgateway" }}
{{- end -}}
