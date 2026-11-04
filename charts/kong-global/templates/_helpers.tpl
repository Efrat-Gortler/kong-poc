{{/* Annotation that makes a cluster-scoped Kong object belong to this leg's controller only */}}
{{- define "kong-global.classAnnotation" -}}
kubernetes.io/ingress.class: {{ .Values.global.kong.ingressClass | quote }}
{{- end -}}

{{- define "kong-global.labels" -}}
app.kubernetes.io/part-of: kong-poc
app.kubernetes.io/managed-by: {{ .Release.Service }}
kong-poc/leg: {{ .Values.global.leg }}
{{- end -}}
