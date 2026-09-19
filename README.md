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
- **Composition avançada (Golang)**: XRD `XDataPlaneAdvanced` / claim `AdvancedDataPlane`, composta por uma **Crossplane Composition Function em Go** (`function/`), que cria `Namespace + ConfigMap + Deployment (com resources/labels padronizados) + Service`. A imagem da function é publicada num **registry OCI privado** (`registry/`) rodando no hub. Cada instância de dataplane avançado é declarada como uma pasta com `values.yaml` no repositório Gogs `dataplanes` (repo próprio, separado da plataforma); um `ApplicationSet` do ArgoCD transforma cada pasta numa release Helm. Toda Composition (baseline e avançada) é instalada/atualizada via **Helm chart** (`charts/`), nunca por diretório solto. Veja [specs/002-golang-composition-pipeline/](specs/002-golang-composition-pipeline/) para o design completo.

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
cd function && make TAG=v0.1.1        # docker build + crossplane xpkg build + push
# sem `make` no Windows/Git Bash: rode os três passos do function/Makefile manualmente
cd ..
./scripts/11-push-dataplanes-repo.sh  # cria o repo "dataplanes" no Gogs e registra no ArgoCD
```

Provisionar um dataplane = criar uma pasta com `values.yaml` no repo `dataplanes`
(veja [specs/002-golang-composition-pipeline/contracts/dataplane-instance-values.md](specs/002-golang-composition-pipeline/contracts/dataplane-instance-values.md)):

```yaml
# dataplanes/meu-dataplane/values.yaml
spoke: spoke-01
image: nginxdemos/hello
replicas: 1
config:
  greeting: ola
```

```bash
git -C ../dataplanes add meu-dataplane && git -C ../dataplanes commit -m "add meu-dataplane"
git -C ../dataplanes push gogs main

# o ApplicationSet gitops/apps/dataplanes-appset.yaml descobre a pasta e cria a Application
kubectl --context k3d-hub -n argocd get application dataplane-meu-dataplane
kubectl --context k3d-hub get advanceddataplane meu-dataplane
kubectl --context k3d-spoke-01 -n dp-meu-dataplane get deploy,svc,cm
```

Remover a pasta remove o dataplane (a `Application` gerada é podada pelo ApplicationSet,
o que cascateia a exclusão da claim e dos recursos no spoke).

**Registry privado**: `https://registry.127-0-0-1.nip.io` (push) /
`registry.registry.svc.cluster.local:5000` (pull, de dentro do cluster). O node do
hub resolve esse hostname interno via `scripts/12-configure-hub-registry-mirror.sh`
(mirror de containerd), já que `*.svc.cluster.local` só resolve dentro de pods, não
no node.

### Acessar as UIs

**Opção 1: via nip.io (HTTPS direto na porta 443 do host)**

Adicione ao seu `/etc/hosts` (ou `C:\Windows\System32\drivers\etc\hosts` no Windows):

```
127.0.0.1 argocd.127-0-0-1.nip.io
127.0.0.1 git.127-0-0-1.nip.io
```

Depois acesse direto (ignore avisos de certificado auto-assinado/não confiável):
- **ArgoCD**: https://argocd.127-0-0-1.nip.io
- **Gogs**: https://git.127-0-0-1.nip.io

Credenciais:
- ArgoCD: **sem login** — acesso anônimo habilitado com role `admin` (lab local, sem exposição externa; ver `scripts/06-install-argocd.sh`). Se preferir reativar o login, remova `users.anonymous.enabled` do `argocd-cm` e `policy.default` do `argocd-rbac-cm` — a senha inicial do admin continua disponível em `argocd-initial-admin-secret` (`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
- Gogs: `gitadmin` / `ChangeMe123!`

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
gitops/apps/               Applications filhas + o ApplicationSet "dataplanes"
gitops/argocd/             Ingress/TLS do ArgoCD e Gogs, ClusterIssuers, config do Traefik
registry/                 manifests do registry OCI privado (Deployment/Service/Ingress/Certificate)
charts/dataplane-baseline/   XRD + Composition baseline (P&T), empacotado como Helm chart
charts/dataplane-advanced/   XRD + Function + Composition avançada (pipeline), Helm chart
charts/dataplane-instance/   chart minúsculo que renderiza 1 claim AdvancedDataPlane a partir de values.yaml
function/                 código-fonte Go da Composition Function (function-sdk-go) + Dockerfile + Makefile
crossplane/providers/     Provider (provider-kubernetes)
crossplane/config/         ProviderConfig por spoke (aponta pro secret de kubeconfig)
crossplane/examples/       Claims de exemplo da composition baseline para os dois spokes
scripts/                  automação de todo o setup (numerados na ordem de execução)
specs/002-golang-composition-pipeline/  spec/plan/tasks da composition avançada + registry + dataplanes repo
```

Repositório `dataplanes` (Gogs, separado deste): uma pasta por dataplane avançado,
cada uma com um `values.yaml` — ver seção acima.

## Teardown

```bash
./scripts/99-teardown.sh
```
