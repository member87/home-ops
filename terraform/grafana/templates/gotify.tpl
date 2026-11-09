{{- /*
  Gotify message for the gotify contact point (terraform/grafana/alerting.tf): the JSON
  body of POST /message. Reuses discord.title, discord.severity_icon, discord.labels and
  discord.links from discord.tpl.

  - message: markdown (client::display), each alert with its panel screenshot inline.
  - priority: 10 firing, 4 resolved. Only severity=critical reaches this contact point (see
    the policy in alerting.tf); allow the app's "High priority" channel to override Do Not
    Disturb so they ring at night.
  - client::notification: tapping opens the rule; the first screenshot is the expanded
    notification's big picture.
*/ -}}

{{ define "gotify.alert" -}}
### {{ if eq .Status "firing" }}{{ template "discord.severity_icon" .Labels.severity }}{{ else }}✅{{ end }} {{ or .Annotations.summary .Labels.alertname }}
{{ with .Annotations.description }}{{ . }}
{{ end -}}
{{ template "discord.labels" . -}}
_{{ if eq .Status "firing" }}firing since {{ .StartsAt.UTC.Format "Mon 2 Jan 15:04 UTC" }}{{ else }}resolved {{ .EndsAt.UTC.Format "Mon 2 Jan 15:04 UTC" }}{{ end }}_
{{ with .ImageURL }}
![graph]({{ . }})
{{ end }}
{{ template "discord.links" . }}

{{ end }}

{{ define "gotify.message" -}}
{{ range $i, $alert := .Alerts.Firing }}{{ if lt $i 5 }}{{ template "gotify.alert" $alert }}{{ end }}{{ end -}}
{{ if gt (len .Alerts.Firing) 5 }}_…and {{ len (slice .Alerts.Firing 5) }} more firing_

{{ end -}}
{{ range $i, $alert := .Alerts.Resolved }}{{ if lt $i 5 }}{{ template "gotify.alert" $alert }}{{ end }}{{ end -}}
{{ if gt (len .Alerts.Resolved) 5 }}_…and {{ len (slice .Alerts.Resolved 5) }} more resolved_
{{ end -}}
{{ end }}

{{ define "gotify.payload" -}}
{{- $image := "" -}}
{{- range .Alerts.Firing }}{{ if and .ImageURL (eq $image "") }}{{ $image = .ImageURL }}{{ end }}{{ end -}}
{{- range .Alerts.Resolved }}{{ if and .ImageURL (eq $image "") }}{{ $image = .ImageURL }}{{ end }}{{ end -}}
{{- $priority := 4 -}}
{{- if eq .Status "firing" }}{{ $priority = 10 }}{{ end -}}
{{- $click := coll.Dict "url" (index .Alerts 0).GeneratorURL -}}
{{- $notification := coll.Dict "click" $click -}}
{{- if $image }}{{ $notification = coll.Dict "click" $click "bigImageUrl" $image }}{{ end -}}
{{- data.ToJSON (coll.Dict
      "title" (tmpl.Exec "discord.title" .)
      "message" (tmpl.Exec "gotify.message" .)
      "priority" $priority
      "extras" (coll.Dict
        "client::display" (coll.Dict "contentType" "text/markdown")
        "client::notification" $notification)) -}}
{{- end }}
