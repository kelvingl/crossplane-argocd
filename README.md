# argo-crossplane lab

Lab local com **k3d + ArgoCD (app of apps) + Crossplane (hub and spoke) + Gogs**.

## Arquitetura

```
                        ┌───────────────────────────────────────────┐
                        │              cluster "hub"                │
                        │                                           │
                        │   ┌────────┐   ┌────────┐   ┌──────────┐  │
                        │   │  Gogs  │◄──┤ ArgoCD │   │Crossplane│  │
                        │   │ (git)  │   │(app of │   │  (core + │  │
                        │   │        │   │ apps)  │──►│providers)│  │
                        │   └────────┘   └────────┘   └────┬─────┘  │
                        └───────────────────────────────────┼───────┘
                                                              │ provider-kubernetes
                                        ┌─────────────────────┼─────────────────────┐
                                        │                     │                     │
                                 ┌──────▼──────┐       ┌──────▼──────┐              │
                                 │ spoke-01    │       │ spoke-02    │  (dataplanes) │
                                 │ (dataplane) │       │ (dataplane) │              │
                                 └─────────────┘       └─────────────┘              │
                                                                                     │
                        3 clusters k3d na mesma rede docker "hublab" ─────────────────┘
```

- **Hub**: cluster `hub` roda ArgoCD, Gogs e o control plane do Crossplane (core + `provider-kubernetes`).
- **Spokes**: clusters `spoke-01` e `spoke-02` são os *dataplanes* — não rodam Crossplane nem ArgoCD, apenas recebem recursos provisionados a partir do hub via `provider-kubernetes`.
- **App of apps**: uma única `Application` raiz (`gitops/root/app-of-apps.yaml`) aponta para `gitops/apps/`, que contém uma `Application` filha por componente da plataforma (Gogs, Crossplane core, Providers, ProviderConfigs, Compositions). Cada filha tem uma `sync-wave` para ordenar a instalação.
- **Hub and spoke no Crossplane**: cada spoke é registrado no hub como um `ProviderConfig` do `provider-kubernetes`, apontando para um `Secret` com o kubeconfig do spoke (criado fora do Git, via script). A Composition de teste usa esse `ProviderConfig` para decidir em qual spoke provisionar o recurso.
- **Composition baseline**: XRD `XDataPlane` / claim `DataPlane` (Patch-and-Transform clássico) que cria `Namespace + Deployment + Service` no spoke escolhido (`spec.parameters.spoke: spoke-01|spoke-02`), demonstrando o modelo hub-and-spoke provisionando um "dataplane" real.
- **Composition avançada (Golang)**: XRD `XDataPlaneAdvanced` / claim `AdvancedDataPlane`, composta por uma **Crossplane Composition Function em Go** (`compositions/dataplane-advanced/function/`), que cria `Namespace + ConfigMap + Deployment (com resources/labels padronizados) + Service`. A imagem da function é publicada num **registry OCI privado** (`registry/`) rodando no hub. Cada spoke tem um arquivo `dataplanes/<spoke>.yaml` no repositório Gogs `dataplanes` (repo próprio, separado da plataforma), listando os claims de Composition e os charts Helm que rodam nele; um `ApplicationSet` do ArgoCD lê cada arquivo e cria uma `Application` por entrada. Toda Composition (baseline e avançada) é instalada/atualizada via **Helm chart** (`compositions/*/chart/`), nunca por diretório solto — cada Composition tem sua própria pasta em `compositions/` com um `Makefile` (dev/build/push/test); veja o `Makefile` na raiz do repo. Veja [specs/002-golang-composition-pipeline/](specs/002-golang-composition-pipeline/) para o design completo.
- **Composition S3 (MiniStack)**: XRD `XS3Bucket` / claim `S3Bucket` que provisiona um bucket S3 real (via `provider-aws-s3`) dentro do **[MiniStack](https://ministack.org)** (`ministack/`), um emulador local de serviços AWS rodando no hub — sem tocar em AWS de verdade. A UI é o **[StackPort](https://stackport.cloud)** (`davireis/stackport`), um browser universal de recursos AWS que aponta pra qualquer endpoint compatível. `crossplane/config/providerconfig-ministack.yaml` aponta o `provider-aws-s3` para o endpoint interno do MiniStack com credenciais fake (`test`/`test`, padrão universal de emuladores desse tipo). Nome do bucket é opcional (`spec.parameters.bucketName`, default `s3-<nome-do-claim>`). Veja `compositions/s3-bucket/`.

## Pré-requisitos

- Docker (Rancher Desktop / Docker Desktop) rodando
- `kubectl`, `helm` (já instalados neste ambiente)
- `k3d` e `argocd` CLI (instalados em `~/bin`, ver `scripts/01-install-tools.sh` se precisar reinstalar)

## Passo a passo

Rode os scripts em ordem (todos em `scripts/`, bash/Git Bash):

```bash
./scripts/01-install-tools.sh      # baixa k3d + argocd CLI (idempotente)
./scripts/02-create-clusters.sh    # cria hub, spoke-01, spoke-02 na mesma rede docker
./scripts/03-register-spokes.sh    # gera secrets de kubeconfig dos spokes no hub
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

### Testar a composition baseline (hub and spoke)

```bash
kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-01.yaml
kubectl --context k3d-hub apply -f crossplane/examples/claim-dataplane-spoke-02.yaml

# acompanhar
kubectl --context k3d-hub get dataplanes.lab.example.org
kubectl --context k3d-hub get managed   # Objects criados pelo provider-kubernetes

# validar que o recurso realmente foi parar no spoke certo
kubectl --context k3d-spoke-01 -n dp-demo-01 get deploy,svc
kubectl --context k3d-spoke-02 -n dp-demo-02 get deploy,svc
```

### Testar a composition avançada (Golang) e o repositório `dataplanes`

Setup (uma vez): builda e publica a imagem da function no registry privado, e cria
o repositório `dataplanes` no Gogs:

```bash
make release-dataplane-advanced       # build (docker + xpkg) + push da imagem da function
# sem `make` no Windows/Git Bash: rode os passos de
# compositions/dataplane-advanced/function/Makefile manualmente
./scripts/11-push-dataplanes-repo.sh  # cria o repo "dataplanes" no Gogs e registra no ArgoCD
./scripts/16-register-argocd-clusters.sh  # registra no ArgoCD (Settings > Clusters) cada spoke
                                           # declarado em dataplanes/<spoke>.yaml no repo dataplanes
```

**Terminologia**: spoke = cluster = dataplane (o mesmo cluster k3d). Cada um tem
**um arquivo** no repo `dataplanes`, `dataplanes/<spoke>.yaml`, listando tudo que
roda nele — charts Helm (aplicados direto no cluster do spoke) e claims de
Composition (aplicadas no hub/control-plane, único lugar onde o Crossplane
roda). Veja o [README do repo `dataplanes`](../dataplanes/README.md) para o
formato completo.

```yaml
# dataplanes/spoke-01.yaml
cluster: spoke-01

charts:                    # Helm chart aplicado DIRETO no spoke (novo desde
  - name: hello             # que os spokes são Clusters registrados no ArgoCD)
    chart: charts/hello
    values:
      replicas: 1

compositions:               # claim de Composition, aplicada no hub;
  - name: adv-01             # "spoke" é injetado automaticamente
    composition: dataplane-advanced
    values:
      image: nginxdemos/hello
      replicas: 1
      config:
        greeting: hello-from-adv-01
```

```bash
git -C ../dataplanes add dataplanes/spoke-01.yaml
git -C ../dataplanes commit -m "add spoke-01"
git -C ../dataplanes push gogs main

# o ApplicationSet gitops/apps/dataplanes-appset.yaml lê o arquivo e cria uma
# Application "dataplane-spoke-01", que por sua vez cria uma Application filha
# por entrada de charts/compositions (charts/dataplane-cluster no repo platform)
kubectl --context k3d-hub -n argocd get application -l ""  | grep dataplane-spoke-01
kubectl --context k3d-hub get advanceddataplane adv-01
kubectl --context k3d-spoke-01 -n dp-adv-01 get deploy,svc,cm
kubectl --context k3d-spoke-01 -n default get deploy,svc spoke-01-hello   # o chart direto
```

Editar `charts:`/`compositions:` em `dataplanes/<spoke>.yaml` (e dar `push`) é o
suficiente para provisionar, mudar ou remover o que roda naquele cluster —
remover uma entrada poda a Application filha correspondente, o que cascateia a
exclusão do claim/recursos.

**Registry privado**: `https://registry.127-0-0-1.nip.io` (push) /
`registry.registry.svc.cluster.local:5000` (pull, de dentro do cluster). O node do
hub resolve esse hostname interno via `scripts/12-configure-hub-registry-mirror.sh`
(mirror de containerd), já que `*.svc.cluster.local` só resolve dentro de pods, não
no node.

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
```

Depois acesse direto (ignore avisos de certificado auto-assinado/não confiável):
- **ArgoCD**: https://argocd.127-0-0-1.nip.io
- **Gogs**: https://git.127-0-0-1.nip.io
- **StackPort (UI do MiniStack)**: https://stackport.127-0-0-1.nip.io — serve UI e API
  na mesma porta (8080), então funciona normalmente pelo Ingress/nip.io, sem precisar
  de port-forward dedicado.

Credenciais:
- ArgoCD: **sem login** — acesso anônimo habilitado com role `admin` (lab local, sem exposição externa; ver `scripts/06-install-argocd.sh`). Se preferir reativar o login, remova `users.anonymous.enabled` do `argocd-cm` e `policy.default` do `argocd-rbac-cm` — a senha inicial do admin continua disponível em `argocd-initial-admin-secret` (`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

Em **Settings > Clusters** o ArgoCD mostra `spoke-01` e `spoke-02` como clusters
registrados (além do `in-cluster`, que é o próprio hub). A **lista** de quais
spokes registrar vem do Git — o campo `cluster:` de cada
`dataplanes/<spoke>.yaml` no repositório `dataplanes` — mas a criação do
Secret de credenciais em si continua imperativa, via
`scripts/16-register-argocd-clusters.sh` (que clona o repo `dataplanes` e usa
o mesmo kubeconfig que `scripts/03-register-spokes.sh` já gera). Registrar o
cluster é o que torna possível endereçar uma `Application` direto a um spoke
(`destination.name: spoke-01`) — usado pelas entradas `charts:` de cada
`dataplanes/<spoke>.yaml` (ver seção acima e `docs/architecture.md`/ADR-029).
Compositions continuam só no hub, via Crossplane/`provider-kubernetes`.
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
gitops/apps/               Applications filhas + o ApplicationSet "dataplanes" (lê dataplanes/*.yaml)
charts/dataplane-cluster/  chart usado pelo ApplicationSet "dataplanes" (renderiza as Applications
                             filhas de cada dataplanes/<spoke>.yaml — uma por chart/composition)
gitops/argocd/             Ingress/TLS do ArgoCD e Gogs, ClusterIssuers, config do Traefik
registry/                 manifests do registry OCI privado (Deployment/Service/Ingress/Certificate)
ministack/                manifests do MiniStack + StackPort UI (emulador local de AWS)
compositions/              uma pasta por Composition, cada uma com seu próprio Makefile (dev/build/push/test)
├── dataplane-baseline/       XRD + Composition baseline (P&T)
│   ├── Makefile
│   └── chart/                 Helm chart (empacota o XRD/Composition, sem imagem)
├── dataplane-advanced/       XRD + Function + Composition avançada (pipeline)
│   ├── Makefile
│   ├── chart/                 Helm chart (XRD + Function + Composition)
│   ├── instance-chart/        chart minúsculo: renderiza 1 claim AdvancedDataPlane a partir de values.yaml
│   └── function/              código-fonte Go da Composition Function (function-sdk-go) + Dockerfile + Makefile
└── s3-bucket/                XRD + Composition que cria um bucket S3 no MiniStack (provider-aws-s3)
    ├── Makefile
    ├── chart/                 Helm chart (XRD + Composition, sem imagem)
    └── examples/               claim de exemplo
Makefile                   orquestra as Compositions acima (build-all/push-all/test-all/...)
crossplane/providers/     Providers: provider-kubernetes (spokes) e provider-aws-s3 (MiniStack)
crossplane/config/         ProviderConfig por spoke + ProviderConfig "ministack" (endpoint do emulador)
crossplane/examples/       Claims de exemplo da composition baseline para os dois spokes
scripts/                  automação de todo o setup (numerados na ordem de execução)
specs/002-golang-composition-pipeline/  spec/plan/tasks da composition avançada + registry + dataplanes repo
docs/                      arquitetura, design das Compositions, log de decisões (ADR) e fluxo GitOps — veja docs/README.md
```

Repositório `dataplanes` (Gogs, separado deste): uma pasta por dataplane avançado,
cada uma com um `values.yaml` — ver seção acima.

## Teardown

```bash
./scripts/99-teardown.sh
```
