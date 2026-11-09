{{- /*
  Discord notification for the discord contact point (terraform/grafana/alerting.tf).

  The message is the post's text and the title a coloured embed under it (red while firing,
  green once resolved), followed by one embed per alert screenshot from the Alert Rules
  dashboard. Discord renders markdown in the text: headings, bold, inline code, masked links,
  "-#" subtext and <t:unix:R> timestamps, which every client shows in its own timezone.

  Grafana truncates the message at 2000 characters (masked links count in full), so a group
  lists at most three alerts of each state and counts the rest.
*/ -}}

{{ define "discord.severity_icon" -}}
{{ if eq . "critical" }}🔴{{ else if eq . "warning" }}🟠{{ else }}🔵{{ end }}
{{- end }}

{{ define "discord.title" -}}
{{ if eq .Status "firing" -}}
{{ template "discord.severity_icon" .CommonLabels.severity }} {{ .CommonLabels.alertname }}
{{- if gt (len .Alerts.Firing) 1 }} · {{ len .Alerts.Firing }} firing{{ end }}
{{- if gt (len .Alerts.Resolved) 0 }} · {{ len .Alerts.Resolved }} resolved{{ end }}
{{- else -}}
✅ Resolved · {{ .CommonLabels.alertname }}
{{- if gt (len .Alerts.Resolved) 1 }} · {{ len .Alerts.Resolved }} alerts{{ end }}
{{- end }}
{{- end }}

{{- /* Labels worth reading: alertname, severity and the folder are already in the title. */ -}}
{{ define "discord.labels" -}}
{{ $first := true -}}
{{ range .Labels.SortedPairs -}}
{{ if not (match "^(alertname|severity|grafana_folder|__.*)$" .Name) -}}
{{ if $first }}{{ $first = false }}{{ else }} · {{ end }}**{{ .Name }}** `{{ .Value }}`
{{- end }}
{{- end }}
{{- if not $first }}
{{ end -}}
{{- end }}

{{- /* Every rule here reduces its query into B and thresholds B in C. */ -}}
{{ define "discord.values" -}}
{{ range $ref, $value := .Values -}}
{{ if eq $ref "B" }} · value `{{ printf "%.6g" $value }}`{{ end -}}
{{ end -}}
{{- end }}

{{ define "discord.links" -}}
{{ if .GeneratorURL }}[Rule]({{ .GeneratorURL }}){{ end -}}
{{ if .PanelURL }} · [Graph]({{ .PanelURL }}){{ else if .DashboardURL }} · [Dashboard]({{ .DashboardURL }}){{ end -}}
{{ if and .SilenceURL (eq .Status "firing") }} · [Silence]({{ .SilenceURL }}){{ end -}}
{{- end }}

{{ define "discord.alert" -}}
### {{ if eq .Status "firing" }}{{ template "discord.severity_icon" .Labels.severity }}{{ else }}✅{{ end }} {{ or .Annotations.summary .Labels.alertname }}
{{ with .Annotations.description }}{{ . }}
{{ end -}}
{{ template "discord.labels" . -}}
-# {{ if eq .Status "firing" -}}
firing since <t:{{ .StartsAt.Unix }}:R>
{{- else -}}
resolved <t:{{ .EndsAt.Unix }}:R> · started <t:{{ .StartsAt.Unix }}:f>
{{- end }}
{{- template "discord.values" . }}
{{ template "discord.links" . }}
{{ end }}

{{ define "discord.alert_list" -}}
{{ range $i, $alert := . -}}
{{ if lt $i 3 }}{{ template "discord.alert" $alert }}{{ end -}}
{{ end -}}
{{ if gt (len .) 3 }}-# …and {{ len (slice . 3) }} more
{{ end -}}
{{ end }}

{{ define "discord.message" -}}
{{ template "discord.alert_list" .Alerts.Firing -}}
{{ template "discord.alert_list" .Alerts.Resolved -}}
{{ end }}
