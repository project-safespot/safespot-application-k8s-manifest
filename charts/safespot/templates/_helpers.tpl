{{/*
albLoadBalancerAttributes builds the comma-separated value for the
alb.ingress.kubernetes.io/load-balancer-attributes annotation.

Merges ingress.alb.loadBalancerAttributes (arbitrary key=value strings) with
access log attributes when ingress.alb.accessLogs.enabled=true.

Returns empty string when:
  - ingress.className is not "alb" (nginx etc. → annotation must not appear)
  - no loadBalancerAttributes configured and access logs disabled
*/}}
{{- define "safespot.albLoadBalancerAttributes" -}}
{{- if eq .Values.ingress.className "alb" -}}
  {{- $attrs := list -}}
  {{- range .Values.ingress.alb.loadBalancerAttributes -}}
    {{- $attrs = append $attrs . -}}
  {{- end -}}
  {{- if .Values.ingress.alb.accessLogs.enabled -}}
    {{- $attrs = append $attrs "access_logs.s3.enabled=true" -}}
    {{- $attrs = append $attrs (printf "access_logs.s3.bucket=%s" .Values.ingress.alb.accessLogs.bucket) -}}
    {{- $attrs = append $attrs (printf "access_logs.s3.prefix=%s" .Values.ingress.alb.accessLogs.prefix) -}}
  {{- end -}}
  {{- join "," $attrs -}}
{{- end -}}
{{- end -}}
