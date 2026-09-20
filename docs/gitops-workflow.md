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

`gitops/apps/dataplanes-appset.yaml` usa o gerador git `directories`
apontando para o repositório Gogs `dataplanes` (`path: "*"` — todo diretório
de topo vira uma entrada). Para cada diretório encontrado, o template gera
uma `Application` `dataplane-<nome-do-diretório>` **multi-source**:

1. **fonte 1** — este repositório (`platform`), caminho
   `compositions/dataplane-advanced/instance-chart` (o chart minúsculo que
   renderiza um único claim `AdvancedDataPlane`), com
   `helm.valueFiles: [$values/<diretório>/values.yaml]`.
2. **fonte 2** — o repositório `dataplanes`, referenciado só como `ref: values`
   (não é renderizado como chart, só fornece o `values.yaml` que a fonte 1
   consome).

**Fluxo ponta a ponta para provisionar um dataplane avançado**:

```
1. Criar uma pasta em ../dataplanes/<nome>/values.yaml
   (spoke, image, replicas, config — ver
   specs/002-golang-composition-pipeline/contracts/dataplane-instance-values.md)
2. git add / commit / push para o remote "gogs" do repo dataplanes
   (scripts/11-push-dataplanes-repo.sh cuida da criação do repo + registro
   do Repository Secret no ArgoCD, na primeira vez)
3. O ApplicationSet detecta o novo diretório (git generator "directories")
   e cria a Application "dataplane-<nome>"
4. Essa Application renderiza um claim AdvancedDataPlane via instance-chart
5. A Composition avançada (função Go) compõe Namespace+ConfigMap+
   Deployment+Service como Objects do provider-kubernetes
6. provider-kubernetes aplica esses Objects no spoke indicado em
   values.yaml (spoke: spoke-01|spoke-02)
```

**Remover** a pasta remove o dataplane: o `ApplicationSet` poda a
`Application` gerada, o que cascateia a exclusão do claim e, por sua vez, dos
recursos compostos no spoke — sem tocar em nenhum arquivo compartilhado
(chart, `ApplicationSet`), verificado durante a US3 da feature 002
(adicionar `adv-03`, remover `adv-02`, `adv-01`/`adv-03` permanecem intactos).

**Armadilha conhecida (não um bug, um comportamento a saber destravar)**: os
caches em camada do ArgoCD (Redis + cache de listagem git do
`argocd-repo-server`) podem sobreviver ao requeue de 3 minutos do controller
do `ApplicationSet`, atrasando a detecção de um diretório novo/renomeado/
removido. Se isso acontecer:

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
