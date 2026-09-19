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
- **Composition de teste**: XRD `XDataPlane` / claim `DataPlane` que cria `Namespace + Deployment + Service` no spoke escolhido (`spec.parameters.spoke: spoke-01|spoke-02`), demonstrando o modelo hub-and-spoke provisionando um "dataplane" real.

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

### Testar a composition (hub and spoke)

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
- ArgoCD: `admin` / senha em `scripts/06-install-argocd.sh`
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
gitops/apps/               Applications filhas: gogs, crossplane, providers, providerconfigs, compositions
crossplane/providers/     Provider (provider-kubernetes)
crossplane/config/         ProviderConfig por spoke (aponta pro secret de kubeconfig)
crossplane/compositions/  XRD + Composition de teste (XDataPlane / DataPlane)
crossplane/examples/       Claims de exemplo para os dois spokes
scripts/                  automação de todo o setup (numerados na ordem de execução)
```

## Teardown

```bash
./scripts/99-teardown.sh
```
