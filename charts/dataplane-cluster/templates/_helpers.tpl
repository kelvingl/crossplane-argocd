{{/*
Mapeia o nome de uma Composition (campo "composition" em
dataplanes/<spoke>.yaml) para o caminho, neste mesmo repositório (platform),
do instance-chart que sabe renderizar um claim dela. Composition sem
instance-chart ainda (dataplane-baseline, s3-bucket) falha explicitamente em
vez de silenciosamente não fazer nada.
*/}}
{{- define "dataplane-cluster.compositionChartPath" -}}
{{- if eq . "dataplane-advanced" -}}
compositions/dataplane-advanced/instance-chart
{{- else -}}
{{- fail (printf "composição '%s' não tem instance-chart conhecido (só dataplane-advanced hoje) — ver charts/dataplane-cluster/templates/_helpers.tpl" .) -}}
{{- end -}}
{{- end -}}
