{{ define "__discord_subject" }}[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ if gt (.Alerts.Resolved | len) 0 }}, RESOLVED:{{ .Alerts.Resolved | len }}{{ end }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }} {{ if gt (len .CommonLabels) (len .GroupLabels) }}({{ with .CommonLabels.Remove .GroupLabels.Names }}{{ .Values | join " " }}{{ end }}){{ end }}{{ end }}

{{ define "__discord_values_list" }}{{ if len .Values }}{{ $first := true }}{{ range $refID, $value := .Values -}}
{{ if $first }}{{ $first = false }}{{ else }}, {{ end }}{{ $refID }}={{ $value }}{{ end -}}
{{ else }}[no value]{{ end }}{{ end }}

{{ define "__discord_alert_list" }}
{{ range . -}}
Value: {{ template "__discord_values_list" . }}
{{ if len .Labels -}}
Labels:
{{ range .Labels.SortedPairs -}}
- {{ .Name }} = {{ .Value }}
{{ end -}}
{{ end -}}
{{ if len .Annotations -}}
Annotations:
{{ range .Annotations.SortedPairs -}}
- {{ .Name }} = {{ .Value }}
{{ end -}}
{{ end -}}
{{ if .GeneratorURL -}}
Source: {{ .GeneratorURL }}
{{ end -}}
{{ if and false .SilenceURL -}}{{/* Disabled, takes too much place. */}}
Silence: {{ .SilenceURL }}
{{ end -}}
{{ if .DashboardURL -}}
Dashboard: {{ .DashboardURL }}
{{ end -}}
{{ if .PanelURL -}}
Panel: {{ .PanelURL }}
{{ end }}
{{ end -}}
{{ end -}}

{{ define "discord.title" }}{{ template "__discord_subject" . }}{{ end }}

{{ define "discord.message" -}}
{{ if gt (len .Alerts.Firing) 0 }}# Firing{{ template "__discord_alert_list" .Alerts.Firing }}{{ end -}}
{{ if gt (len .Alerts.Resolved) 0 }}# Resolved{{ template "__discord_alert_list" .Alerts.Resolved }}{{ end -}}
{{ end -}}
