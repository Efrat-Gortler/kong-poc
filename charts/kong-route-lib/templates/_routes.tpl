{{- /*
Usage in a component chart:  {{ include "kong-route-lib.routes" . }}

values:
  kongRoutes:
    - name: orders-create          # HTTPRoute name = logical route name (used by blocking)
      path: /orders
      method: POST                 # optional; omitted = any method
      service: orders              # Service name in the same namespace
      port: 8080
      routeLimitPerSecond: 400     # optional, route-wide, per leg   (rate-limiting)
      routeLimitPerMinute: 20      # optional, route-wide, per leg   (rate-limiting)
      userLimitPerMinute: 100      # optional, per caller, all legs  (rate-limiting-advanced)
      stripPath: false             # optional

needs .Values.global (environments/<leg>.yaml): kong.gatewayName, redis.*
*/ -}}
{{- define "kong-route-lib.routes" -}}
{{- $g := .Values.global -}}
{{- $root := . -}}
{{- range $r := .Values.kongRoutes }}
{{- $plugins := list -}}
{{- if or $r.routeLimitPerSecond $r.routeLimitPerMinute }}{{ $plugins = append $plugins (printf "%s-rl-route" $r.name) }}{{ end -}}
{{- if $r.userLimitPerMinute }}{{ $plugins = append $plugins (printf "%s-rl-user" $r.name) }}{{ end }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ $r.name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    app.kubernetes.io/part-of: kong-poc
    kong-poc/route: {{ $r.name }}
  annotations:
    konghq.com/strip-path: {{ $r.stripPath | default false | quote }}
    {{- if $plugins }}
    konghq.com/plugins: {{ join "," $plugins | quote }}
    {{- end }}
spec:
  parentRefs:
    - name: {{ $g.kong.gatewayName }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: {{ $r.path }}
          {{- with $r.method }}
          method: {{ . }}
          {{- end }}
      backendRefs:
        - name: {{ $r.service }}
          port: {{ $r.port }}
{{- if or $r.routeLimitPerSecond $r.routeLimitPerMinute }}
---
# Route-wide limit, PER LEG. The counter lives in this leg's own Redis logical DB,
# so the legs never add up (rate-limiting has no namespace option; its keys are
# built from route/service IDs, which would be identical across real clusters).
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: {{ $r.name }}-rl-route
  namespace: {{ $root.Release.Namespace }}
plugin: rate-limiting
config:
  {{- with $r.routeLimitPerSecond }}
  second: {{ . }}
  {{- end }}
  {{- with $r.routeLimitPerMinute }}
  minute: {{ . }}
  {{- end }}
  limit_by: service
  policy: redis
  fault_tolerant: true
  hide_client_headers: false
  redis:
    host: {{ $g.redis.host }}
    port: {{ $g.redis.port }}
    database: {{ $g.redis.routeLimitDatabase }}
configPatches:
  - path: /redis/password
    valueFrom:
      secretKeyRef:
        name: {{ $g.redis.passwordSecret }}
        key: password
{{- end }}
{{- if $r.userLimitPerMinute }}
---
# Per-caller limit on this route, SHARED BY ALL LEGS: same Redis DB and the same
# explicit namespace in every leg -> one counter per (route, caller_id).
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: {{ $r.name }}-rl-user
  namespace: {{ $root.Release.Namespace }}
plugin: rate-limiting-advanced
{{- if dig "userLimitFirst" true ($root.Values.kongRouteDefaults | default dict) }}
# Check the caller's own limit before the route-wide one, so a noisy caller
# does not burn the route budget of everybody else (Enterprise dynamic ordering).
ordering:
  before:
    access: [rate-limiting]
{{- end }}
config:
  limit: [{{ $r.userLimitPerMinute }}]
  window_size: [60]
  window_type: sliding
  identifier: credential
  namespace: {{ printf "%s-user" $r.name }}
  strategy: redis
  sync_rate: 0          # synchronous: exact count across legs (one Redis round trip)
  hide_client_headers: false
  redis:
    host: {{ $g.redis.host }}
    port: {{ $g.redis.port }}
    database: {{ $g.redis.userLimitDatabase }}
configPatches:
  - path: /redis/password
    valueFrom:
      secretKeyRef:
        name: {{ $g.redis.passwordSecret }}
        key: password
{{- end }}
{{- end }}
{{- end -}}

{{- /* Service annotations for upstream timeouts (milliseconds) */ -}}
{{- define "kong-route-lib.serviceTimeouts" -}}
{{- with .Values.kongTimeouts }}
konghq.com/connect-timeout: {{ .connectMs | default 5000 | quote }}
konghq.com/read-timeout: {{ .readMs | default 60000 | quote }}
konghq.com/write-timeout: {{ .writeMs | default 60000 | quote }}
{{- end }}
{{- end -}}
