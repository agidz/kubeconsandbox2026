{{- define "local-model.name" -}}
  {{- required "The local deployment requires model.name" .Values.model.name -}}
{{- end -}}

{{- define "local-model.image" -}}
  {{- $name := include "local-model.name" . -}}
  {{- $revision := required "The local deployment requires model.revision" .Values.model.revision -}}
  {{- printf "harbor.%s/models/%s:%s" .Values.baseDomain $name (trunc 12 $revision) -}}
{{- end -}}
