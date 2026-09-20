# Compositions

Três Crossplane Compositions existem hoje neste repositório, cada uma em sua
própria pasta sob `compositions/<name>/`, com seu próprio `Makefile` expondo o
mesmo conjunto de alvos (`dev`, `build`, `push`, `test`, `clean`) e um Helm
chart em `chart/` — nenhuma Composition é instalada por diretório solto
(Constitution Technology Constraints: "Any Composition... MUST be packaged and
released as a Helm chart"). O `Makefile` na raiz do repo apenas itera sobre
`COMPOSITIONS := dataplane-baseline dataplane-advanced s3-bucket`, delegando
para o Makefile de cada uma (`make build-all`, `make test-<nome>`,
`make release-<nome>`, etc.).

## 1. `dataplane-baseline` — Patch-and-Transform clássico

**XRD**: `xdataplanes.lab.example.org` / claim `DataPlane`
(`compositions/dataplane-baseline/chart/templates/xrd-dataplane.yaml`).

**Parâmetros** (`spec.parameters`): `spoke` (string, obrigatório — deve bater
com o nome de um `ProviderConfig` do provider-kubernetes), `image` (default
`nginxdemos/hello`), `replicas` (default `1`).

**O que é composto**: três `kubernetes.crossplane.io/v1alpha2` `Object`s —
`Namespace` (`dp-<claim-name>`), `Deployment` (`dataplane-<claim-name>`,
imagem/replicas parametrizáveis) e `Service` (porta 80), todos escritos via
patches `CombineFromComposite`/`FromCompositeFieldPath` clássicos do modelo
`spec.resources` (Crossplane v1.x, sem function-pipeline). O nome de cada
recurso é derivado do label estável `crossplane.io/claim-name` (não do nome
gerado da XR — ver decisão correspondente em `docs/decisions.md`).

**Como é empacotado**: `compositions/dataplane-baseline/chart/` — chart Helm
mínimo, cujos templates são o XRD e a Composition originais movidos
byte-a-byte (verificado via `helm template | diff` na migração — feature 002).
Instalado pela Application `crossplane-compositions`
(`gitops/apps/crossplane-compositions.yaml`, sync-wave `"1"`, releaseName
`dataplane-baseline`).

**Makefile** (`compositions/dataplane-baseline/Makefile`): `dev`/`build` fazem
`helm lint`/`helm template`; `push` é um no-op (não há imagem — é YAML puro);
`test` aplica um claim de exemplo, espera `Ready`, confirma e remove.

**Exemplos**: `crossplane/examples/claim-dataplane-spoke-01.yaml` e
`claim-dataplane-spoke-02.yaml`.

## 2. `dataplane-advanced` — Composition Function em Go

**XRD**: `xdataplaneadvanceds.lab.example.org` / claim `AdvancedDataPlane`
(`compositions/dataplane-advanced/chart/templates/xrd-dataplane-advanced.yaml`).

**Parâmetros**: `spoke` (obrigatório), `image` (default `nginxdemos/hello`),
`replicas` (default `1`), `config` (mapa string→string, vira `data` de um
ConfigMap).

**Pipeline**: a Composition usa `spec.mode: Pipeline` com um único step
(`compose-dataplane`) que chama o `Function` `dataplane-function`
(`compositions/dataplane-advanced/chart/templates/function.yaml`, imagem
padrão `registry.registry.svc.cluster.local:5000/dataplane-function:v0.1.1`,
`packagePullPolicy: Always`).

**Como o Go mapeia para os recursos compostos**
(`compositions/dataplane-advanced/function/fn.go`, `RunFunction`):
1. Lê a XR observada, extrai `crossplane.io/claim-name` (fallback: nome da
   XR), e `spec.parameters.{spoke,image,replicas,config}` (com defaults para
   `image`/`replicas` se ausentes/nulos).
2. Monta quatro recursos desejados via `newDesiredObject`, cada um
   embrulhado como um `kubernetes.crossplane.io/v1alpha2` `Object` apontando
   `providerConfigRef.name` para o spoke escolhido — o mesmo mecanismo de
   entrega do baseline, só que montado em Go em vez de patches YAML:
   - `namespace`: `dp-<claim>`, com labels padronizadas
     (`app.kubernetes.io/{managed-by,instance,part-of}`).
   - `configmap`: `dataplane-<claim>-config`, dados de `spec.parameters.config`.
   - `deployment`: `dataplane-<claim>`, com `resources.requests/limits` fixos
     (`100m`/`128Mi` requests, `250m`/`256Mi` limits), `envFrom` referenciando
     o ConfigMap, labels padronizadas no Pod template.
   - `service`: `dataplane-<claim>`, porta 80.
3. Cada `resource.DesiredComposed` é criado com `Ready: resource.ReadyTrue`
   explícito — sem isso a XR/claim nunca reporta `Ready: "True"`, porque
   `provider-kubernetes` `Object`s não recebem uma checagem de prontidão
   implícita como os recursos do patch-and-transform clássico recebem (gotcha
   real, descoberto durante a US1 da feature 002 — ver `docs/decisions.md`).
4. `response.SetDesiredComposedResources` entrega os quatro recursos ao
   runtime do Crossplane.

**Como é empacotado**: `compositions/dataplane-advanced/chart/` (XRD +
`Function` + `Composition`, releaseName `dataplane-advanced`, Application
`crossplane-compositions-advanced`, sync-wave `"1"`) e um segundo chart minúsculo,
`compositions/dataplane-advanced/instance-chart/`, que só renderiza **um** claim
`AdvancedDataPlane` a partir de `values.yaml` (falha rápido com `fail` do Helm
se `spoke` não estiver setado) — é esse instance-chart que o `ApplicationSet`
de dataplanes usa como fonte 1 (ver `docs/gitops-workflow.md`).

**Makefile** (`compositions/dataplane-advanced/Makefile`): é o ponto de
entrada nível-Composition; delega o build/push da imagem para
`function/Makefile` e faz `helm lint`/`template` dos dois charts. `dev` roda
`go vet`/`go build` só do código Go (feedback rápido, sem Docker). `test`
instala um claim descartável via `instance-chart`, espera `Ready`, desinstala.

**Makefile da function** (`compositions/dataplane-advanced/function/Makefile`):
`image` (`docker build`) → `xpkg` (`crossplane xpkg build
--embed-runtime-image=...`, porque um Function package do Crossplane é um
xpkg envolvendo a imagem OCI, não a imagem crua) → `push` (`crossplane xpkg
push --insecure-skip-tls-verify` para o registry privado).

## 3. `s3-bucket` — Bucket S3 no MiniStack

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

## Padrão comum entre as três

Todas as Compositions:
- selecionam o alvo (spoke ou MiniStack) só por `providerConfigRef.name`, nunca por
  endpoint/credencial embutido (Constitution Principle II);
- têm pelo menos um exemplo aplicado e verificado de ponta a ponta antes de
  serem consideradas prontas (Constitution Principle IV);
- são entregues via Helm chart e instaladas por uma `Application` ArgoCD
  dedicada, nunca por `directory.recurse` (Constitution Technology
  Constraints, amendment v1.1.0);
- expõem o mesmo target-surface de Makefile (`dev`/`build`/`push`/`test`/`clean`)
  para que `make release-all`/`make test-all` na raiz do repo funcionem sem
  conhecimento especial de qual Composition é qual.
