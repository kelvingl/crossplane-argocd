{{/*
Mapeia o nome de uma Composition (campo "composition" em
dataplanes/<spoke>.yaml) para o caminho, neste mesmo repositório (platform),
do instance-chart que sabe renderizar um claim dela. Nenhuma Composition tem
instance-chart no momento (dataplane-advanced foi removida) — qualquer
entrada em "compositions:" falha explicitamente em vez de silenciosamente
não fazer nada, até uma nova Composition com instance-chart ser adicionada
aqui.
*/}}
{{- define "dataplane-cluster.compositionChartPath" -}}
{{- fail (printf "composição '%s' não tem instance-chart conhecido — ver charts/dataplane-cluster/templates/_helpers.tpl" .) -}}
{{- end -}}
