# Compositions

Duas Crossplane Compositions existem hoje neste repositório, cada uma em sua
própria pasta sob `compositions/<name>/`, com seu próprio `Makefile` expondo o
mesmo conjunto de alvos (`dev`, `build`, `push`, `test`, `clean`) e um Helm
chart em `chart/` — nenhuma Composition é instalada por diretório solto
(Constitution Technology Constraints: "Any Composition... MUST be packaged and
released as a Helm chart"). O `Makefile` na raiz do repo apenas itera sobre
`COMPOSITIONS := dataplane-cluster s3-bucket`, delegando para o Makefile de
cada uma (`make build-all`, `make test-<nome>`, `make release-<nome>`, etc.).

> Uma terceira Composition, `dataplane-advanced` (XRD `XDataPlaneAdvanced` /
> claim `AdvancedDataPlane`, Composition Function em Go, descrita em
> [specs/002-golang-composition-pipeline/](../specs/002-golang-composition-pipeline/))
> existiu neste repositório e foi removida por completo — pedido explícito do
> operador, sem defeito técnico associado. Ver ADR correspondente em
> `docs/decisions.md`.

## 1. `dataplane-cluster` — cria o spoke em si (vcluster)

**XRD**: `xdataplanes.lab.example.org` / claim `DataPlane`
(`compositions/dataplane-cluster/chart/templates/xrd-dataplane.yaml`).

**Reaproveita o nome de uma Composition retirada (feature 001)**: até a
feature 003 (vcluster-dataplanes), `XDataPlane`/`DataPlane` era a Composition
*baseline* — Patch-and-Transform clássico, criava `Namespace + Deployment +
Service` **dentro** de um spoke já existente (`spec.parameters.spoke`,
`image`, `replicas`). Essa Composition e seus exemplos (`demo-01`/`demo-02`)
foram removidos por completo, e o mesmo nome de XRD/claim foi reaproveitado
para um conceito diferente: o spoke **em si**, não um workload dentro dele.
Ver ADR correspondente em `docs/decisions.md`.

**Parâmetros** (`spec.parameters`): nenhum obrigatório — só
`kubernetesVersion` (opcional, repassado ao chart do vcluster se definido). O
nome do spoke vem de `metadata.name` do claim, não de um parâmetro.

**O que é composto**: um único recurso `helm.crossplane.io/v1beta1` `Release`
(provider `provider-helm`), instalando o chart oficial do vcluster
(`https://charts.loft.sh`, chart `vcluster`) — release name e namespace
ambos = nome do claim. `spec.forProvider.values.exportKubeConfig.server` é
sobrescrito para a forma curta `https://<nome>.<nome>:443` (o certificado do
próprio vcluster só cobre essa forma como SAN, não o FQDN completo
`...svc.cluster.local` — confirmado testando, não suposto).

**Como é empacotado**: `compositions/dataplane-cluster/chart/`, releaseName
`dataplane-cluster`. Instalado pela Application `crossplane-compositions`
(`gitops/apps/crossplane-compositions.yaml`, sync-wave `"1"`).

**Makefile** (`compositions/dataplane-cluster/Makefile`): `dev`/`build` fazem
`helm lint`/`helm template`; `push` é um no-op (não há imagem — é YAML puro);
`test` aplica um claim de exemplo, espera `Ready` (o vcluster de fato subir
pode levar ~1min), remove.

**Exemplo**: `compositions/dataplane-cluster/examples/claim-dataplane.yaml`.

Normalmente uma claim `DataPlane` não é aplicada à mão: o `ApplicationSet`
`dataplanes` gera uma automaticamente para cada `dataplanes/<spoke>.yaml` no
repositório `dataplanes` (mesmo arquivo que lista o que roda naquele spoke —
ver `docs/gitops-workflow.md`).

## 2. `s3-bucket` — Bucket S3 no MiniStack

**XRD**: `xs3buckets.lab.example.org` / claim `S3Bucket`
(`compositions/s3-bucket/chart/templates/xrd-s3bucket.yaml`).

**Parâmetros**: `bucketName` (opcional, default `s3-<claim-name>`), `region`
(default `us-east-1`, não validado pelo MiniStack).

**O que é composto**: um único recurso `s3.aws.upbound.io/v1beta1` `Bucket`
(provider `provider-aws-s3` da Upbound, v1.14.0), via Patch-and-Transform
clássico — não usa function-pipeline. `providerConfigRef.name: ministack` é fixo
na base do recurso (não vem de `spec.parameters.spoke`, porque este alvo não é
um spoke k3d: é o MiniStack rodando no hub via
`crossplane/config/providerconfig-ministack.yaml`). O nome do bucket é resolvido
por dois patches em sequência: primeiro `CombineFromComposite` calcula
`s3-<claim-name>`, depois um `FromCompositeFieldPath` opcional sobrescreve com
`spec.parameters.bucketName` se o claim o define. O nome final é refletido em
`status.bucketName`.

**Como é empacotado**: `compositions/s3-bucket/chart/`, releaseName
`s3-bucket`, Application `crossplane-compositions-s3`, sync-wave `"1"`.

**Makefile** (`compositions/s3-bucket/Makefile`): igual ao baseline — sem
imagem para publicar (`push` é no-op). `test` aplica
`examples/claim-s3bucket.yaml`, espera `Ready`, lê `status.bucketName`, remove.

**Exemplo**: `compositions/s3-bucket/examples/claim-s3bucket.yaml`.

## Padrão comum entre as duas

Todas as Compositions:
- selecionam o alvo só por `providerConfigRef.name`, nunca por
  endpoint/credencial embutido (Constitution Principle II) — `s3-bucket`
  endereça o MiniStack já existente por esse nome; `dataplane-cluster` é a
  exceção estrutural: ele *cria* o alvo, então seu `providerConfigRef`
  (`provider-helm`) é sempre o mesmo (`hub`), fixo;
- têm pelo menos um exemplo aplicado e verificado de ponta a ponta antes de
  serem consideradas prontas (Constitution Principle IV);
- são entregues via Helm chart e instaladas por uma `Application` ArgoCD
  dedicada, nunca por `directory.recurse` (Constitution Technology
  Constraints, amendment v1.1.0);
- expõem o mesmo target-surface de Makefile (`dev`/`build`/`push`/`test`/`clean`)
  para que `make release-all`/`make test-all` na raiz do repo funcionem sem
  conhecimento especial de qual Composition é qual.
