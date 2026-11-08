{{- /*
Platform helpers. IDENTICAL copy in every chart of this repo (charts/*/templates/_platform.tpl);
edit one, then run scripts/sync-platform-helpers.sh.

global.platform: openshift | kubernetes   (from cluster/values-<platform>.yaml)
*/ -}}

{{- define "poc.platform" -}}
{{- (.Values.global | default dict).platform | default "openshift" -}}
{{- end -}}

{{- define "poc.isOpenShift" -}}
{{- if eq (include "poc.platform" .) "openshift" -}}true{{- end -}}
{{- end -}}

{{- /* Pod-level securityContext. OpenShift assigns UIDs through the SCC (restricted-v2),
so nothing is set there. Plain Kubernetes gets the same shape explicitly: an arbitrary
non-root UID, like OpenShift would give, so images that assume root fail here too. */ -}}
{{- define "poc.podSecurityContext" -}}
{{- if not (include "poc.isOpenShift" .) }}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
{{- end }}
{{- end -}}

{{- /* External host name: <prefix>.<appsDomain> */ -}}
{{- define "poc.host" -}}
{{- $ := index . 0 -}}
{{- printf "%s.%s" (index . 1) ((($.Values.global | default dict).appsDomain) | default "apps-crc.testing") -}}
{{- end -}}

{{- /* Expose a Service: Route on OpenShift, Ingress elsewhere.
args: list $ <object name> <host prefix> <service> <service port name> */ -}}
{{- define "poc.expose" -}}
{{- $ := index . 0 -}}
{{- $name := index . 1 -}}
{{- $host := include "poc.host" (list $ (index . 2)) -}}
{{- $svc := index . 3 -}}
{{- $port := index . 4 -}}
{{- if include "poc.isOpenShift" $ }}
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ $name }}
spec:
  host: {{ $host }}
  to: { kind: Service, name: {{ $svc }} }
  port: { targetPort: {{ $port }} }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
{{- else }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $name }}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: {{ ($.Values.global | default dict).ingressClass | default "traefik" }}
  rules:
    - host: {{ $host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $svc }}
                port:
                  name: {{ $port }}
{{- end }}
{{- end -}}

{{- /* Namespace selector for traffic coming from the cluster's ingress router */ -}}
{{- define "poc.routerNamespaceSelector" -}}
{{- if include "poc.isOpenShift" . }}
namespaceSelector:
  matchLabels:
    policy-group.network.openshift.io/ingress: ""
{{- else }}
namespaceSelector:
  matchLabels:
    kubernetes.io/metadata.name: kube-system
{{- end }}
{{- end -}}
