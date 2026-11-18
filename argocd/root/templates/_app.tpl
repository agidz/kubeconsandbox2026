{{- define "kcs.applicationHeader" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ quote .wave }}
  {{- if .cascade }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  {{- end }}
{{- end -}}

{{- define "kcs.sync" -}}
destination:
  namespace: {{ .namespace }}
  server: https://kubernetes.default.svc
syncPolicy:
  {{- if .auto }}
  automated:
    prune: true
    selfHeal: true
  {{- end }}
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
  retry:
    limit: 5
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 1m
{{- end -}}

{{/* A registry chart can consume values and an optional manifest source from Git. */}}
{{- define "kcs.app" -}}
{{- $install := .root.Values -}}
{{- $pin := index $install.charts .chart -}}
{{ include "kcs.applicationHeader" . }}
spec:
  project: {{ .project }}
  sources:
    - chart: {{ .chart }}
      repoURL: {{ $install.chartRegistry }}
      targetRevision: {{ quote (required (printf "Missing chart version for %s" .chart) $pin.version) }}
      helm:
        releaseName: {{ .name }}
        ignoreMissingValueFiles: true
        valueFiles:
          - $values/values/{{ .name }}/values.yaml
          - $values/envs/{{ $install.env }}/values/{{ .name }}.yaml
        {{- if .skipCrds }}
        skipCrds: true
        {{- end }}
        {{- with .parameters }}
        parameters: {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .values }}
        valuesObject: {{- toYaml . | nindent 10 }}
        {{- end }}
    - ref: values
      repoURL: {{ $install.repoURL }}
      targetRevision: {{ $install.repoRevision }}
    {{- if .manifests }}
    - path: manifests/{{ .name }}
      repoURL: {{ $install.repoURL }}
      targetRevision: {{ $install.repoRevision }}
      {{- if .manifestsHelm }}
      helm:
        releaseName: {{ .name }}-manifests
        ignoreMissingValueFiles: true
        valueFiles:
          - $values/envs/{{ $install.env }}/values/{{ .name }}-manifests.yaml
        parameters:
          - name: baseDomain
            value: {{ quote $install.baseDomain }}
          - name: modelProvider
            value: {{ quote $install.modelProvider }}
          - name: modelName
            value: {{ quote $install.modelName }}
          - name: localModelName
            value: {{ ($install.localModel | default dict).name | default "" | quote }}
          - name: goAdkImage
            value: {{ index ($install.images | default dict) "kagent-golang-adk" | default "" | quote }}
      {{- end }}
    {{- end }}
  {{- include "kcs.sync" . | nindent 2 }}
{{- end -}}

{{/* Every profile includes all earlier numbered layers. */}}
{{- define "kcs.layer" -}}
  {{- $profiles := list "bootstrap" "platform" "identity" "agents" "delegation" "full" -}}
  {{- $through := 0 -}}
  {{- range $index, $profile := $profiles -}}
    {{- if eq $profile $.root.Values.profile -}}
      {{- $through = $index -}}
    {{- end -}}
  {{- end -}}
  {{- if ge $through (int .n) -}}true{{- end -}}
{{- end -}}

{{/* A repository-only application can target plain manifests or an in-tree chart. */}}
{{- define "kcs.gitapp" -}}
{{- $install := .root.Values -}}
{{ include "kcs.applicationHeader" . }}
spec:
  project: {{ .project }}
  source:
    path: {{ .path }}
    repoURL: {{ $install.repoURL }}
    targetRevision: {{ $install.repoRevision }}
    {{- if .helm }}
    helm:
      parameters:
        - name: baseDomain
          value: {{ quote $install.baseDomain }}
      releaseName: {{ .name }}
      {{- with .values }}
      valuesObject: {{- toYaml . | nindent 8 }}
      {{- end }}
    {{- end }}
  {{- include "kcs.sync" (merge (dict "auto" true) .) | nindent 2 }}
{{- end -}}
