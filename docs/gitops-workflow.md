# Fluxo de trabalho GitOps

Como uma mudança local vira, de fato, um recurso rodando em um cluster deste
lab — remotes, ordenação de sync-wave, o padrão `ApplicationSet` para o repo
`dataplanes`, e o fluxo de release das Compositions via Makefile.

## Remotes: `origin` vs `gogs`, e por que os dois existem

Este repositório pode ter dois remotes configurados:

- **`gogs`** — `http://gitadmin:...@localhost:<porta>/gitadmin/platform.git`
  (ou, de dentro do cluster, `http://gogs.gogs.svc.cluster.local:3000/gitadmin/platform.git`).
  É **o único remote que o ArgoCD reconcilia**. Ele é criado/atualizado por
  `scripts/05-push-to-gogs.sh` (via port-forward temporário durante o script).
- **`origin`** — GitHub, opcional, só para colaboração/backup humano. O ArgoCD
  nunca fala com ele.

**Regra prática**: antes de confiar que o ArgoCD vai refletir uma mudança, o
remote `gogs` precisa estar atualizado — `git push origin` sozinho não basta,
porque o ArgoCD nunca lê do GitHub (Constitution: Development Workflow /
Principle I).

O mesmo padrão se repete para o repositório separado `dataplanes`
(`scripts/11-push-dataplanes-repo.sh`): ele só existe no Gogs, sem um
`origin` GitHub equivalente documentado neste repo.

## Ordem de sync-wave: por que essa ordem

A árvore app-of-apps (`gitops/apps/*.yaml`, descoberta por
`root-app-of-apps` a partir de `gitops/root/app-of-apps.yaml`) usa três waves:

- **wave `"0"`**: `gogs`, `crossplane` (core), `registry`, `ministack`. Nenhuma
  dessas depende de nada além do cluster hub já existir — mas tudo na wave
  `"1"` depende de pelo menos uma delas.
- **wave `"1"`**: `crossplane-providers`, e as três Compositions
  (`crossplane-compositions`, `crossplane-compositions-advanced`,
  `crossplane-compositions-s3`). Precisam do Crossplane core (wave 0) já
  instalado; a Composition avançada também precisa do registry (wave 0) já
  estar de pé para a imagem da Function poder ser referenciada (mesmo que o
  `Function` resource em si só fique `HEALTHY` depois de a imagem ter sido
  publicada manualmente — ver `docs/compositions.md`); a Composition
  `s3-bucket` precisa do MiniStack (wave 0) já respondendo em
  `ministack.ministack.svc.cluster.local:4566`.
- **wave `"2"`**: `crossplane-config` (os `ProviderConfig`s, que referenciam
  providers instalados na wave 1), `argocd-networking` (Ingress/TLS —
  independente das outras, mas mantido na wave mais alta por convenção), e o
  `ApplicationSet` `dataplanes` (precisa que a XRD `XDataPlaneAdvanced` já
  exista no cluster, o que só acontece depois que
  `crossplane-compositions-advanced` da wave 1 sincronizou).

Regra geral usada neste repo (Constitution Principle III): a sync-wave de uma
Application reflete a ordem de dependência real, nunca uma preferência
estética — core antes de providers, providers antes de
ProviderConfigs/Compositions que os referenciam.

## O padrão `ApplicationSet` para o repo `dataplanes`

Terminologia: spoke = cluster = dataplane; control-plane = hub.

`gitops/apps/dataplanes-appset.yaml` usa o gerador git `files` apontando para
`dataplanes/*.yaml` no repositório Gogs `dataplanes` — **um arquivo por
cluster**, não mais uma pasta por instância. Cada `dataplanes/<spoke>.yaml`
lista dois tipos de coisa para aquele cluster:

```yaml
cluster: spoke-01
charts:            # Helm charts aplicados DIRETO no spoke
  - name: hello
    chart: charts/hello
    values: { replicas: 1 }
compositions:      # claims de Composition, aplicadas no hub
  - name: adv-01
    composition: dataplane-advanced
    values: { image: nginxdemos/hello, replicas: 1, config: { greeting: hello-from-adv-01 } }
```

Para cada arquivo, o `ApplicationSet` gera **uma Application "wrapper"**
(`dataplane-<spoke>`) **multi-source**:

1. **fonte 1** — este repositório (`platform`), caminho
   `charts/dataplane-cluster` (o chart que faz o fan-out — ver abaixo), com
   `helm.valueFiles: [$values/dataplanes/<spoke>.yaml]` — o próprio arquivo
   do spoke, lido como values do chart (seus campos batem 1:1 com
   `charts/dataplane-cluster/values.yaml`).
2. **fonte 2** — o repositório `dataplanes`, referenciado só como `ref: values`.

Essa Application wrapper não cria recursos de workload diretamente: seu
único papel é `range` sobre `.Values.charts` e `.Values.compositions` e
emitir, para cada entrada, **uma Application filha própria**
(`dataplane-<spoke>-<nome>`) — o mesmo padrão de "Application gerando
Application" que já existia no `root-app-of-apps`, só que agora
parametrizado por dados vindos do Git em vez de arquivos fixos:

- entradas de **`charts`**: `destination.name: <spoke>` — endereça o
  Cluster do ArgoCD registrado por `scripts/16-register-argocd-clusters.sh`
  diretamente, sem Crossplane no meio. Fonte: o próprio repo `dataplanes`,
  caminho da entrada (`charts/<nome>`).
- entradas de **`compositions`**: `destination.server` é sempre o hub — o
  Crossplane só roda lá. Fonte: este repositório (`platform`), resolvida a
  partir do nome da composition via um mapa fixo em
  `charts/dataplane-cluster/templates/_helpers.tpl` (hoje só
  `dataplane-advanced` → `compositions/dataplane-advanced/instance-chart`).
  O parâmetro `spoke` é injetado automaticamente a partir de `cluster:`.

**Fluxo ponta a ponta para provisionar algo num spoke**:

```
1. Editar/criar dataplanes/<spoke>.yaml — adicionar uma entrada em
   "charts" (chart direto no cluster) ou "compositions" (claim no hub)
2. git add / commit / push para o remote "gogs" do repo dataplanes
   (scripts/11-push-dataplanes-repo.sh cuida da criação do repo, e
   scripts/16-register-argocd-clusters.sh registra o spoke como Cluster
   no ArgoCD, na primeira vez que aparece)
3. O ApplicationSet detecta o arquivo (git generator "files") e
   (re)sincroniza a Application "dataplane-<spoke>"
4. Essa Application renderiza charts/dataplane-cluster, que emite uma
   Application filha por entrada de charts/compositions
5a. Application filha de "charts": Helm chart aplicado direto no spoke
    (destination.name), sem Crossplane
5b. Application filha de "compositions": renderiza um claim (ex.:
    AdvancedDataPlane) no hub; a Composition (função Go) compõe os
    recursos reais como Objects do provider-kubernetes; provider-kubernetes
    aplica esses Objects no spoke indicado em "cluster:"
```

**Remover** uma entrada de `charts`/`compositions` remove só aquilo: a
Application filha correspondente é podada, cascateando a exclusão do
claim/recursos. Remover o arquivo `dataplanes/<spoke>.yaml` inteiro remove
tudo que aquele cluster tinha declarado (a Application wrapper e todas as
filhas). Verificado de ponta a ponta na migração da estrutura antiga
(uma pasta por instância `adv-01`/`adv-03`) para esta — ver ADR-029 em
`docs/decisions.md`, incluindo dois erros reais de templating pegos no
processo (YAML inválido por `{{ }}` não citado, e o parâmetro errado do
gerador `files` para o nome do arquivo).

**Armadilha conhecida (não um bug, um comportamento a saber destravar)**: os
caches em camada do ArgoCD (Redis + cache de listagem git do
`argocd-repo-server`) podem sobreviver ao requeue de 3 minutos do controller
do `ApplicationSet`, atrasando a detecção de um arquivo/diretório novo,
renomeado ou removido — ou pior, fazendo o `ApplicationSet` continuar
gerando `Application`s a partir de um **generator/template antigo**, mesmo
depois de um `git push` com a definição nova (foi exatamente isso que
aconteceu na migração para `dataplanes/*.yaml`: mesmo com o arquivo já
corrigido no Git, o controller continuou usando o generator `directories`
antigo até Redis + repo-server + applicationset-controller serem
reiniciados). Se isso acontecer:

```bash
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-redis
kubectl --context k3d-hub -n argocd rollout restart deployment/argocd-repo-server deployment/argocd-applicationset-controller
```

(ver `docs/decisions.md`, ADR-021 e ADR-023, para o porquê e para o efeito
colateral real que reiniciar o Redis isoladamente já causou uma vez).

## Fluxo de release de uma Composition (Makefile-driven)

Cada Composition em `compositions/<nome>/` expõe o mesmo alvo de Makefile:
`dev`, `build`, `push`, `test`, `clean`. O `Makefile` da raiz do repo itera
sobre `COMPOSITIONS := dataplane-baseline dataplane-advanced s3-bucket`.

**Compositions sem imagem** (`dataplane-baseline`, `s3-bucket`):
- `dev`/`build`: `helm lint` + `helm template` do chart (nenhuma imagem
  envolvida — `push` é um no-op).
- `test`: aplica um claim de exemplo contra o cluster real, espera
  `Ready`, confirma o estado, remove.

**`dataplane-advanced`** (com imagem da Function):
- `make dev` (ou `make -C compositions/dataplane-advanced dev`): `go
  vet`/`go build` só do código Go — feedback mais rápido enquanto se edita
  `fn.go`, sem Docker.
- `make build`: builda a imagem runtime (`docker build`), empacota como
  Crossplane xpkg (`crossplane xpkg build --embed-runtime-image=...`) e
  valida (`helm lint`/`template`) os dois charts (`chart/` e
  `instance-chart/`).
- `make push` (ou `make release-dataplane-advanced` = build + push):
  publica o xpkg no registry privado (`crossplane xpkg push
  --insecure-skip-tls-verify`).
- Depois de publicar uma nova tag, o `values.yaml` do chart
  (`compositions/dataplane-advanced/chart/values.yaml`) precisa ser
  atualizado com a nova tag e o commit/push feito para o `gogs` — só então o
  ArgoCD atualiza o recurso `Function` via sync Helm (é assim que a US2 da
  feature 002 foi de fato verificada: a correção real de `v0.1.0` →
  `v0.1.1`, não uma demonstração).
- `make test`: instala um claim descartável via `instance-chart`, espera
  `Ready`, desinstala — exige a Application
  `crossplane-compositions-advanced` já sincronizada e a imagem já publicada.

**Atalhos na raiz do repo**: `make build-all`/`push-all`/`release-all`/
`test-all`/`dev-all`/`clean-all` fazem fan-out sobre as três Compositions;
`make build-<nome>`, `make test-<nome>`, etc. rodam um alvo único; `make
release-<nome>` é `build-<nome>` seguido de `push-<nome>`.

## Checklist mental de "minha mudança vai aparecer no cluster?"

1. O arquivo mudado está sob um caminho que alguma `Application`/
   `ApplicationSet` referencia (`gitops/apps/*.yaml` lista `source.path` ou
   `sources[].path` de cada uma)?
2. O commit foi enviado para o remote `gogs` (não só `origin`)?
3. Se for uma Composition com imagem (`dataplane-advanced`): a imagem nova
   foi publicada no registry (`make push`/`release-<nome>`) **antes** de o
   `values.yaml` do chart referenciar a nova tag?
4. Se for uma instância de dataplane avançado: o diretório está no repo
   `dataplanes` (não neste repositório de plataforma), e o `ApplicationSet`
   já teve tempo de notar o diretório novo (ou os caches do ArgoCD foram
   reiniciados manualmente, se demorou demais)?
