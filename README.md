# argo-crossplane lab

Lab local com **k3d + ArgoCD (app of apps) + Crossplane (hub and spoke) + Gogs**.

## Arquitetura

```
                        ┌─────────────────────────────────────────────────────┐
                        │                   cluster "hub" (k3d)                │
                        │                                                       │
                        │   ┌────────┐   ┌────────┐   ┌──────────┐             │
                        │   │  Gogs  │◄──┤ ArgoCD │   │Crossplane│             │
                        │   │ (git)  │   │(app of │   │  (core + │             │
                        │   │        │   │ apps)  │──►│providers)│             │
                        │   └────────┘   └────────┘   └────┬─────┘             │
                        │                                   │ provider-helm     │
                        │                    ┌──────────────┼──────────────┐    │
                        │                    │              │              │    │
                        │             ┌──────▼──────┐┌──────▼──────┐┌─────▼───┐│
                        │             │  spoke-01   ││  spoke-02   ││ spoke-N ││
                        │             │ (vcluster)  ││ (vcluster)  ││(vcluster)││
                        │             └─────────────┘└─────────────┘└─────────┘│
                        └─────────────────────────────────────────────────────┘
                    único cluster k3d real do lab — spokes são vclusters dentro dele
```

Terminologia: **spoke = cluster = dataplane** = control plane; **control-plane = hub**.

- **Hub**: único cluster k3d real deste lab. Roda ArgoCD, Gogs, o control plane do Crossplane (core + providers) — e, desde a feature 003, também os **vclusters** que são os spokes/dataplanes.
- **Spokes**: cada spoke é um **vcluster** ([loft-sh/vcluster](https://vcluster.com)) rodando como workload dentro do hub — não um cluster k3d separado. Não rodam Crossplane nem ArgoCD; recebem recursos de duas formas: (a) via `provider-kubernetes`, como efeito de uma claim de Composition; (b) charts Helm aplicados **direto** pelo ArgoCD, já que cada spoke é um Cluster registrado no ArgoCD — inclusive os addons (ver abaixo).
- **App of apps**: uma única `Application` raiz (`gitops/root/app-of-apps.yaml`) aponta para `gitops/apps/`, que contém uma `Application` filha por componente da plataforma (Gogs, Crossplane core, Providers, ProviderConfigs, Compositions). Cada filha tem uma `sync-wave` para ordenar a instalação.
- **Ciclo de vida de um spoke**: criar/destruir um spoke é uma operação do Crossplane, não um comando de infraestrutura — um arquivo `dataplanes/<spoke>.yaml` no repositório Gogs `dataplanes` gera automaticamente uma claim `DataPlane` (XRD `XDataPlane`, `compositions/dataplane-cluster/`), que instala o chart oficial do vcluster no hub via `provider-helm`. O mesmo arquivo também registra o spoke no ArgoCD (`scripts/16-register-argocd-clusters.sh`) e lista o que roda nele. Veja [specs/003-vcluster-dataplanes/](specs/003-vcluster-dataplanes/) para o design completo.
- **Addons em todo spoke (`dataplane-addons`)**: um segundo app-of-apps, `gitops/apps/dataplane-addons-appset.yaml`, instala cada chart em `addons/<nome>/` em **todo** spoke registrado no ArgoCD — via um `matrix` generator combinando o gerador `clusters` (filtrado por `lab.example.org/role: dataplane`, para não pegar o `in-cluster`/hub) com um gerador `git` `directories` sobre `addons/*`. Dois addons de exemplo hoje: `prometheus` (servidor + UI em `https://prometheus.<spoke>.127-0-0-1.nip.io`) e `external-dns` (observa `Ingress` no spoke, provider `inmemory`). Ambos só ficam alcançáveis de fora porque o chart do vcluster liga `sync.toHost.ingresses` — um `Ingress` criado dentro do spoke é espelhado para o hub, onde o Traefik/cert-manager reais o veem. Veja `addons/README.md`.
- **Composition S3 (MiniStack)**: XRD `XS3Bucket` / claim `S3Bucket` que provisiona um bucket S3 real (via `provider-aws-s3`) dentro do **[MiniStack](https://ministack.org)** (`ministack/`), um emulador local de serviços AWS rodando no hub — sem tocar em AWS de verdade. A UI é o **[StackPort](https://stackport.cloud)** (`davireis/stackport`), um browser universal de recursos AWS que aponta pra qualquer endpoint compatível. `crossplane/config/providerconfig-ministack.yaml` aponta o `provider-aws-s3` para o endpoint interno do MiniStack com credenciais fake (`test`/`test`, padrão universal de emuladores desse tipo). Nome do bucket é opcional (`spec.parameters.bucketName`, default `s3-<nome-do-claim>`). Veja `compositions/s3-bucket/`.

**Nota**: a Composition avançada em Go (`dataplane-advanced`/`AdvancedDataPlane`, XRD `XDataPlaneAdvanced`) descrita em [specs/002-golang-composition-pipeline/](specs/002-golang-composition-pipeline/) foi removida — não existe mais neste repositório. O registry OCI privado (`registry/`) que hospedava a imagem da sua Function não tem mais nenhum consumidor no momento.

## Pré-requisitos

- Docker (Rancher Desktop / Docker Desktop) rodando
- `kubectl`, `helm` (já instalados neste ambiente)
- `k3d` e `argocd` CLI (instalados em `~/bin`, ver `scripts/01-install-tools.sh` se precisar reinstalar)

## Passo a passo

Rode os scripts em ordem (todos em `scripts/`, bash/Git Bash):

```bash
./scripts/01-install-tools.sh      # baixa k3d + argocd CLI (idempotente)
./scripts/02-create-clusters.sh    # cria só o hub (único cluster k3d real do lab)
./scripts/04-bootstrap-gogs.sh     # sobe o Gogs no hub (fora do GitOps, "bootstrap")
./scripts/05-push-to-gogs.sh       # cria repo + usuário admin no Gogs e faz push deste repo
./scripts/06-install-argocd.sh     # instala o ArgoCD no hub
./scripts/07-bootstrap-gitops.sh   # cria o Repository do Gogs no ArgoCD + a Application raiz (app of apps)
```

Ou tudo de uma vez:

```bash
./scripts/00-up.sh
```

Depois disso o ArgoCD assume a gestão de Gogs, Crossplane core, providers, providerconfigs e compositions via Git.

### Provisionar um novo spoke (dataplane-cluster)

Normalmente isso acontece sozinho: `dataplanes/<spoke>.yaml` no repo `dataplanes`
já gera a claim (veja a seção seguinte). Para testar a Composition isoladamente:

```bash
kubectl --context k3d-hub apply -f compositions/dataplane-cluster/examples/claim-dataplane.yaml

kubectl --context k3d-hub get dataplane dataplane-cluster-test
kubectl --context k3d-hub get release.helm.crossplane.io dataplane-cluster-test
kubectl --context k3d-hub -n dataplane-cluster-test get pods   # o vcluster rodando

kubectl --context k3d-hub delete -f compositions/dataplane-cluster/examples/claim-dataplane.yaml
```

Não existe mais `kubectl --context k3d-spoke-01`: um spoke é um vcluster, acessado
via o `Secret vc-<spoke>` que o próprio chart gera dentro do namespace do spoke
(ver `specs/003-vcluster-dataplanes/quickstart.md` para como montar/usar esse
kubeconfig num pod de debug).

### O repositório `dataplanes`: o que roda em cada spoke

Setup (uma vez): cria o repositório `dataplanes` no Gogs e registra os spokes no
ArgoCD:

```bash
./scripts/11-push-dataplanes-repo.sh      # cria o repo "dataplanes" no Gogs e registra no ArgoCD
./scripts/16-register-argocd-clusters.sh  # registra no ArgoCD (Settings > Clusters) cada spoke
                                           # declarado em dataplanes/<spoke>.yaml no repo dataplanes
```

**Terminologia**: spoke = cluster = dataplane. Cada um tem **um arquivo** no repo
`dataplanes`, `dataplanes/<spoke>.yaml`, listando tudo que roda nele — charts Helm
(aplicados direto no cluster do spoke) e claims de Composition (aplicadas no
hub/control-plane, único lugar onde o Crossplane roda). Veja o
[README do repo `dataplanes`](../dataplanes/README.md) para o formato completo.

```yaml
# dataplanes/spoke-01.yaml
cluster: spoke-01

charts:                    # Helm chart aplicado DIRETO no spoke
  - name: hello
    chart: charts/hello
    values:
      replicas: 1

compositions: []           # claims de Composition, aplicadas no hub — nenhuma
                            # ativa aqui hoje (ver charts/dataplane-cluster/
                            # templates/_helpers.tpl para compositions conhecidas)
```

```bash
git -C ../dataplanes add dataplanes/spoke-01.yaml
git -C ../dataplanes commit -m "add spoke-01"
git -C ../dataplanes push gogs main

# o ApplicationSet gitops/apps/dataplanes-appset.yaml lê o arquivo e cria uma
# Application "dataplane-spoke-01", que por sua vez cria uma Application filha
# por entrada de charts/compositions (charts/dataplane-cluster no repo platform)
kubectl --context k3d-hub -n argocd get application | grep dataplane-spoke-01
# spoke-01 é um vcluster dentro do hub — os recursos ficam visíveis via o
# kubeconfig que o próprio chart gera (Secret vc-spoke-01, namespace spoke-01);
# ver specs/003-vcluster-dataplanes/quickstart.md para o passo a passo completo.
```

Editar `charts:`/`compositions:` em `dataplanes/<spoke>.yaml` (e dar `push`) é o
suficiente para provisionar, mudar ou remover o que roda naquele cluster —
remover uma entrada poda a Application filha correspondente, o que cascateia a
exclusão do claim/recursos.

### Addons em todo spoke (`dataplane-addons`)

Diferente de `dataplanes/<spoke>.yaml` (editado manualmente por spoke), os addons
em `addons/<nome>/` são instalados **automaticamente em todo spoke registrado no
ArgoCD**, via o `ApplicationSet` `dataplane-addons`:

```bash
kubectl --context k3d-hub -n argocd get application | grep dataplane-addons
# dataplane-addons-spoke-01-prometheus, dataplane-addons-spoke-01-external-dns,
# dataplane-addons-spoke-02-prometheus, dataplane-addons-spoke-02-external-dns

curl -sk https://prometheus.spoke-01.127-0-0-1.nip.io/   # UI do Prometheus do spoke-01
```

Adicionar `addons/<nome-novo>/` (um chart Helm válido) faz com que ele apareça em
todo spoke, existente ou futuro, no próximo sync — sem editar o `ApplicationSet`.
Veja `addons/README.md`.

### Testar a composition S3 (MiniStack)

Setup (uma vez): cria o secret de credenciais fake que o `ProviderConfig "ministack"`
referencia (`crossplane/config/providerconfig-ministack.yaml`):

```bash
./scripts/15-register-ministack-credentials.sh
```

```bash
kubectl --context k3d-hub apply -f compositions/s3-bucket/examples/claim-s3bucket.yaml
kubectl --context k3d-hub wait s3bucket/demo-bucket -n default --for=condition=Ready --timeout=60s
kubectl --context k3d-hub get s3bucket demo-bucket -o jsonpath='{.status.bucketName}'
```

Ou via Makefile: `make test-s3-bucket`. O bucket é real dentro do MiniStack — dá pra
conferir também pela UI do StackPort (veja abaixo) ou direto na API S3 emulada:

```bash
kubectl --context k3d-hub -n ministack run s3check --image=curlimages/curl --restart=Never --rm -i \
  -- curl -s http://ministack.ministack.svc.cluster.local:4566/
```

### Acessar as UIs

**Opção 1: via nip.io (HTTPS direto na porta 443 do host)**

Adicione ao seu `/etc/hosts` (ou `C:\Windows\System32\drivers\etc\hosts` no Windows):

```
127.0.0.1 argocd.127-0-0-1.nip.io
127.0.0.1 git.127-0-0-1.nip.io
127.0.0.1 stackport.127-0-0-1.nip.io
127.0.0.1 prometheus.spoke-01.127-0-0-1.nip.io
127.0.0.1 prometheus.spoke-02.127-0-0-1.nip.io
```

Depois acesse direto (ignore avisos de certificado auto-assinado/não confiável):
- **ArgoCD**: https://argocd.127-0-0-1.nip.io
- **Gogs**: https://git.127-0-0-1.nip.io
- **StackPort (UI do MiniStack)**: https://stackport.127-0-0-1.nip.io — serve UI e API
  na mesma porta (8080), então funciona normalmente pelo Ingress/nip.io, sem precisar
  de port-forward dedicado.
- **Prometheus** (um por spoke, addon `dataplane-addons`):
  https://prometheus.spoke-01.127-0-0-1.nip.io,
  https://prometheus.spoke-02.127-0-0-1.nip.io — o `Ingress` é criado dentro do
  vcluster e sincronizado para o hub (`sync.toHost.ingresses`), então cada spoke
  novo precisa da sua própria entrada aqui.

Credenciais:
- ArgoCD: **sem login** — acesso anônimo habilitado com role `admin` (lab local, sem exposição externa; ver `scripts/06-install-argocd.sh`). Se preferir reativar o login, remova `users.anonymous.enabled` do `argocd-cm` e `policy.default` do `argocd-rbac-cm` — a senha inicial do admin continua disponível em `argocd-initial-admin-secret` (`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

Em **Settings > Clusters** o ArgoCD mostra `spoke-01`, `spoke-02` (e qualquer outro
spoke) como clusters registrados (além do `in-cluster`, que é o próprio hub). A
**lista** de quais spokes registrar vem do Git — o campo `cluster:` de cada
`dataplanes/<spoke>.yaml` no repositório `dataplanes` — mas a criação do Secret de
credenciais em si continua imperativa, via
`scripts/16-register-argocd-clusters.sh`, que lê o kubeconfig que o **próprio chart
do vcluster gera em tempo de execução** (Secret `vc-<spoke>`, namespace `<spoke>`,
no hub) — desde a feature 003 não existe mais um passo separado de "registrar o
spoke" via cluster k3d real. Registrar o cluster é o que torna possível endereçar
uma `Application` direto a um spoke (`destination.name: spoke-01`) — usado pelas
entradas `charts:` de cada `dataplanes/<spoke>.yaml`. Compositions continuam só no
hub, via Crossplane/`provider-kubernetes`. Ver
`specs/003-vcluster-dataplanes/` e `docs/decisions.md`.
- Gogs: `gitadmin` / `ChangeMe123!`
- MiniStack/StackPort: sem login (emulador local, credenciais AWS fake `test`/`test`)

**Opção 2: via port-forward (alternativa)**

```bash
./scripts/09-port-forward.sh
```

Depois:
- **ArgoCD HTTPS**: https://localhost:8443
- **Gogs HTTPS**: https://localhost:8443
- **HTTP redirect**: http://localhost:8080 (redireciona para HTTPS)

**Certificados:**
- Todos os certificados HTTPS são auto-assinados pelo cluster
- CA interna: `lab-ca-issuer` (gerada automaticamente)
- Certificados renovam automaticamente 30 dias antes do vencimento
- Porter 80 e 443 do Traefik (LoadBalancer) estão expostas no host via k3d

## Estrutura

```
bootstrap/gogs/          manifests do Gogs (aplicados uma vez fora do Argo; depois o Argo os "adota")
gitops/root/              Application raiz (app of apps)
gitops/apps/               Applications filhas + os ApplicationSets "dataplanes" (lê
                             dataplanes/*.yaml) e "dataplane-addons" (cluster generator)
charts/dataplane-cluster/  chart usado pelo ApplicationSet "dataplanes" (renderiza, para cada
                             dataplanes/<spoke>.yaml: 1 claim DataPlane + 1 Application por
                             entrada de chart/composition)
gitops/argocd/             Ingress/TLS do ArgoCD e Gogs, ClusterIssuers, config do Traefik
addons/                    charts instalados em TODO spoke pelo ApplicationSet "dataplane-addons"
├── prometheus/               servidor Prometheus + UI (Ingress sincronizado do spoke pro hub)
└── external-dns/             observa Ingress no spoke, provider inmemory (demonstra o padrão)
registry/                 manifests do registry OCI privado (Deployment/Service/Ingress/Certificate) —
                            sem consumidor no momento (a composition que o usava foi removida)
ministack/                manifests do MiniStack + StackPort UI (emulador local de AWS)
compositions/              uma pasta por Composition, cada uma com seu próprio Makefile (dev/build/push/test)
├── dataplane-cluster/        XRD XDataPlane / claim DataPlane — cria o spoke em si (vcluster via provider-helm)
│   ├── Makefile
│   ├── chart/                 Helm chart (XRD + Composition)
│   └── examples/               claim de exemplo
└── s3-bucket/                XRD + Composition que cria um bucket S3 no MiniStack (provider-aws-s3)
    ├── Makefile
    ├── chart/                 Helm chart (XRD + Composition, sem imagem)
    └── examples/               claim de exemplo
Makefile                   orquestra as Compositions acima (build-all/push-all/test-all/...)
crossplane/providers/     Providers: provider-kubernetes (spokes), provider-helm (vclusters), provider-aws-s3 (MiniStack)
crossplane/config/         ProviderConfig por spoke (vcluster), ProviderConfig "hub" (provider-helm), "ministack"
scripts/                  automação de todo o setup (numerados na ordem de execução)
specs/003-vcluster-dataplanes/          spec/plan/tasks da migração spoke k3d → vcluster
docs/                      arquitetura, design das Compositions, log de decisões (ADR) e fluxo GitOps — veja docs/README.md
```

Repositório `dataplanes` (Gogs, separado deste): uma pasta por dataplane avançado,
cada uma com um `values.yaml` — ver seção acima.

## Teardown

```bash
./scripts/99-teardown.sh
```
