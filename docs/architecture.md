# Arquitetura

Este documento descreve a topologia atual do lab: o cluster hub e os spokes
vcluster, a árvore app-of-apps do ArgoCD, o papel do Crossplane no modelo
hub-and-spoke, o Gogs como única fonte GitOps, o registry OCI privado e o
emulador de AWS (MiniStack). Tudo aqui reflete o estado real dos manifests em
`gitops/` (tudo que o ArgoCD aplica: `apps/`, `appset/`, `crossplane/`,
`dataplanes-fanout/`, `addons/`, `kubernetes-dashboard/`, `registry/`,
`ministack/`, `argocd/`) e `bootstrap/` (o que roda uma vez, fora do Argo) —
não um design aspiracional.

## Visão geral: 1 cluster k3d real, spokes como vclusters dentro dele

```
hub — único cluster k3d real do lab
spoke-01, spoke-02, ... — vclusters (loft-sh/vcluster) rodando DENTRO do hub
```

Terminologia: **spoke = cluster = dataplane** (o mesmo dataplane, três nomes
pelo mesmo motivo em contextos diferentes); **control-plane = hub**.

- **`hub`**: o único cluster k3d real. Roda ArgoCD, Gogs, o control plane do
  Crossplane (core + providers) — e, desde a feature 003
  (vcluster-dataplanes), também os vclusters que são os spokes. É o único
  ponto de controle da plataforma (Constitution Principle II —
  Hub-and-Spoke Isolation).
- **`spoke-01` / `spoke-02` / ...**: cada um é um vcluster rodando como
  workload (um `StatefulSet` de um pod) dentro do hub — não mais um cluster
  k3d separado (essa mudança é o que a feature 003 entrega; até ela,
  spoke-01/spoke-02 eram clusters k3d reais numa rede Docker compartilhada
  com o hub). Não rodam nenhuma ferramenta de plataforma própria. Recebem
  recursos de duas formas: (a) provisionados a partir do hub via
  `provider-kubernetes` (`kubernetes.crossplane.io/v1alpha2` `Object`), como
  efeito colateral de uma claim de Composition; ou (b) charts Helm aplicados
  **diretamente** pelo ArgoCD, já que cada spoke é um Cluster registrado no
  ArgoCD — sem Crossplane no meio. Ver "`dataplanes/<spoke>.yaml`" abaixo.

## Ciclo de vida de um spoke: a Composition `XDataPlane`

Criar ou destruir um spoke é uma operação do Crossplane, não um comando de
infraestrutura. A Composition `XDataPlane` (claim `DataPlane`,
`gitops/crossplane/compositions/dataplane-cluster/`) compõe um único recurso: um
`helm.crossplane.io/v1beta1` `Release` (via o provider `provider-helm`) que
instala o chart oficial do vcluster (`https://charts.loft.sh`, chart
`vcluster`) dentro do hub, num namespace com o mesmo nome do claim.
`provider-helm` usa credenciais `InjectedIdentity` (sua própria identidade
dentro do cluster) e precisa de permissões equivalentes a `cluster-admin`
(`gitops/crossplane/providers/provider-helm.yaml`) — o conteúdo de um chart Helm é
arbitrário, então não dá pra restringir a um conjunto fixo de recursos como
se faz para `provider-kubernetes`.

O vcluster resultante gera, em tempo de execução, seu próprio Secret de
kubeconfig (`vc-<nome-do-spoke>`, no namespace do spoke) — com chaves já
separadas (`certificate-authority`, `client-certificate`, `client-key`,
`config`), sem precisar de nenhum parsing. O `server` exportado é sobrescrito
pela Composition para a forma curta `https://<nome>.<nome>:443` (não o FQDN
completo `...svc.cluster.local` — o certificado do próprio vcluster só cobre
a forma curta como SAN; usar o FQDN completo falha a verificação TLS,
confirmado testando). TLS real funciona (`certificate-authority` do próprio
Secret), sem precisar de `insecure-skip-tls-verify`.

**IMPORTANTE — este XRD/claim reaproveita o nome da feature 001**: até a
feature 003, `XDataPlane`/`DataPlane` era a Composition *baseline* (P&T
clássico), que criava `Namespace + Deployment + Service` **dentro** de um
spoke já existente. A feature 003 aposentou esse significado inteiramente
(incluindo os exemplos `demo-01`/`demo-02` que ela produzia) e reaproveitou o
mesmo nome de XRD/claim para um conceito bem diferente: o spoke **em si**.
Ver ADR correspondente em `decisions.md`.

## Registro de um spoke: `ProviderConfig` + Cluster do ArgoCD

Cada spoke é registrado no hub como um `ProviderConfig`
(`gitops/crossplane/config/providerconfig-spoke-*.yaml`) apontando para o Secret
`vc-<spoke>` (namespace `<spoke>`, chave `config`) que o próprio vcluster já
gerou — nenhuma credencial é gerada ou copiada à mão. Compositions selecionam
o spoke alvo exclusivamente por `spec.parameters.spoke` →
`providerConfigRef.name`, nunca por endpoint/credencial embutidos.

Cada spoke também é registrado **no ArgoCD** como um Cluster (Secret com label
`argocd.argoproj.io/secret-type: cluster` no namespace `argocd`). A *lista* de
quais spokes registrar vem do Git — o campo `cluster:` de cada
`dataplanes/<spoke>.yaml` no repositório `dataplanes` (mesmo arquivo que
também dispara a criação do `DataPlane` claim e lista o que roda naquele
cluster, ver seção seguinte) — mas a criação do Secret com as credenciais em
si é imperativa, `bootstrap/scripts/16-register-argocd-clusters.sh`, que lê
diretamente o Secret `vc-<spoke>` que o vcluster já gerou (nada de parsing de
kubeconfig via `kubectl config view` como no modelo k3d antigo). Isso faz
`spoke-01`/`spoke-02` aparecerem em Settings > Clusters na UI do ArgoCD, ao
lado do `in-cluster` (o próprio hub) — e é o que torna possível endereçar uma
`Application` direto a um spoke (`destination.name: spoke-01`), usado pelas
entradas `charts:` descritas abaixo.

O registro do `ProviderConfig`/Cluster do ArgoCD continua um passo manual
(script), mesmo com o spoke sendo criado via Crossplane — decisão deliberada
para manter a Composition `XDataPlane` com uma única responsabilidade (criar
o vcluster), sem expandir seu escopo além do que foi pedido.

Duas versões anteriores da lógica de registro no ArgoCD foram tentadas e
descartadas antes desta: uma 100% declarativa via `ApplicationSet` + chart
Helm com a função `lookup` (não funciona — o repo-server do ArgoCD roda
`helm template` sem acesso ao cluster) e uma imperativa com lista de spokes
hardcoded no script (perdeu a propriedade de "a lista vem do Git"). Ver
ADR-027/028/029 em `decisions.md`.

## `dataplanes/<spoke>.yaml`: o que roda em cada cluster

Terminologia: **spoke = cluster = dataplane** — o mesmo cluster k3d, três
nomes pelo mesmo motivo em contextos diferentes; **control-plane = hub**.

Cada spoke tem exatamente um arquivo, `dataplanes/<spoke>.yaml` no
repositório `dataplanes`, listando tudo que roda nele:

```yaml
cluster: spoke-01
charts:                          # Helm charts aplicados DIRETO no cluster do spoke
  - name: hello
    chart: charts/hello/chart     # caminho, no repo dataplanes, até o chart
    values: { replicas: 1 }
compositions: []            # claims de Composition, aplicadas no HUB — nenhuma
                             # composition com instance-chart disponível no momento
```

O `ApplicationSet` `dataplanes` (`gitops/appset/dataplanes-appset.yaml`, no
repo `platform`) usa um gerador git `files` sobre `dataplanes/*.yaml` — um
arquivo, uma Application "wrapper" `dataplane-<spoke>`, que renderiza o chart
`gitops/dataplanes-fanout/chart` (também no repo `platform`). Esse chart faz o
fan-out: para cada entrada de `charts`, emite uma `Application` filha com
`destination.name: <spoke>` (direto no cluster, sem Crossplane); para cada
entrada de `compositions`, emite uma `Application` filha com
`destination.server` = hub, via o instance-chart daquela Composition, com
`spoke` injetado automaticamente. Ver `docs/gitops-workflow.md` para o fluxo
completo e ADR-029 em `decisions.md` para os erros reais de templating
encontrados na migração (YAML quebrado por `{{ }}` não citado; parâmetro
errado do gerador `files` para o nome do arquivo).

## `gitops/addons/<nome>/`: instalado em todo spoke, automaticamente

Diferente de `dataplanes/<spoke>.yaml` (um arquivo por spoke, editado
manualmente), os addons são instalados em **todo** spoke registrado no
ArgoCD sem nenhuma edição por spoke. O `ApplicationSet`
`dataplane-addons` (`gitops/appset/dataplane-addons-appset.yaml`) usa um
gerador `matrix` combinando:

1. o gerador `clusters`, filtrado por `selector.matchLabels:
   lab.example.org/role: dataplane` — sem esse filtro, o gerador `clusters`
   também incluiria o `in-cluster` implícito (o próprio hub), onde nenhum
   addon de spoke faz sentido. O label é aplicado por
   `bootstrap/scripts/16-register-argocd-clusters.sh` no Secret de cada Cluster.
2. um gerador `git` `directories` sobre `gitops/addons/*` (chart Helm por pasta).

O produto cartesiano dos dois gera uma `Application`
(`dataplane-addons-<spoke>-<addon>`) por combinação (spoke × addon), cada
uma com `destination.name: <spoke>` — direto no cluster, sem Crossplane,
mesmo mecanismo das entradas `charts:`. `spoke` é injetado automaticamente
via `valuesObject`. Dois addons de exemplo hoje (`gitops/addons/README.md` tem o
detalhe de cada um):

- **`prometheus`**: servidor Prometheus + UI, exposta via `Ingress` em
  `prometheus.<spoke>.127-0-0-1.nip.io`.
- **`external-dns`**: observa `Ingress` dentro do spoke
  (`domain-filter: <spoke>.127-0-0-1.nip.io`), provider `inmemory` (o
  provedor de testes/demo do próprio projeto — nip.io já resolve qualquer
  subdomínio sozinho, não há um backend de DNS real para gerenciar aqui).

Ambos só ficam alcançáveis de fora do cluster porque
`gitops/crossplane/compositions/dataplane-cluster` liga `sync.toHost.ingresses: true` nos
values do chart do vcluster — um `Ingress` criado **dentro** do spoke é
espelhado para o hub (nome sincronizado, ex.:
`prometheus-x-prometheus-x-spoke-01`), onde o Traefik e o cert-manager reais
(nenhum dos dois roda dentro de um spoke) o enxergam e agem sobre ele.
Confirmado com um teste manual antes de qualquer addon existir: um
`Deployment`+`Service`+`Ingress` de teste dentro de `spoke-01`, HTTP 200,
depois HTTPS 200 com certificado emitido pela `lab-ca-issuer`.

## `dataplane-dashboard`: app-of-apps filtrado a UM spoke

Nem todo app-of-apps precisa ter alvo "todo spoke". `dataplane-dashboard`
(`gitops/appset/dataplane-dashboard-appset.yaml`) usa o mesmo gerador
`clusters` do `dataplane-addons`, mas SEM o gerador `git` `directories` ao
lado (não é um `matrix`, é um gerador `clusters` só) — e com
`selector.matchLabels: lab.example.org/name: spoke-03` em vez de
`lab.example.org/role: dataplane`. Resultado: exatamente uma `Application`
(`dataplane-dashboard-spoke-03`), mesmo com três spokes registrados.

Instala o **Kubernetes Dashboard v2.7.0 sem autenticação** —
`gitops/kubernetes-dashboard/` (fora de `gitops/addons/` de propósito, para
não ser pego pelo gerador `gitops/addons/*` do `dataplane-addons` e acabar instalado
em todo spoke). "Sem autenticação" é uma combinação de três coisas:
`--enable-skip-login` (mostra o botão "Skip" na tela de login),
`--enable-insecure-login` e a `ServiceAccount` do próprio pod ligada a
`cluster-admin` via `ClusterRoleBinding` — sem nenhuma credencial
apresentada, o backend usa a identidade da própria ServiceAccount, que já
tem acesso total. Confirmado com uma chamada de API real, sem nenhum header:
`GET /api/v1/namespace` retornou a lista completa de namespaces do spoke.

Dois problemas reais foram pegos rodando de verdade, não hipotéticos: (1) o
container entra em `panic` na inicialização
(`secrets "kubernetes-dashboard-csrf" not found`) porque a imagem espera três
Secrets (`kubernetes-dashboard-certs`, `-csrf`, `-key-holder`) já existirem
no seu namespace — ela escreve neles em runtime, não os cria do zero; (2) o
flag `--namespace` do Dashboard tem default `kube-system`, então sem
`--namespace={{ .Release.Namespace }}` explícito ele procura seus próprios
Secrets no namespace errado mesmo estando corretamente implantado em
`kubernetes-dashboard`.

## Diagrama de componentes

```mermaid
flowchart TB
    subgraph hub["cluster hub (único cluster k3d real)"]
        direction TB
        Gogs["Gogs\n(git server)"]
        ArgoCD["ArgoCD\n(app-of-apps)"]
        CP["Crossplane core\n+ provider-kubernetes\n+ provider-helm\n+ provider-aws-s3"]
        Registry["Registry OCI privado\n(registry:2)"]
        MiniStack["MiniStack\n(emulador AWS local)"]

        subgraph spoke01["spoke-01 (vcluster)"]
            NS1["hello chart\n+ addons: prometheus, external-dns"]
        end
        subgraph spoke02["spoke-02 (vcluster)"]
            NS2["addons: prometheus, external-dns"]
        end

        ArgoCD -->|reconcilia a partir de| Gogs
        ArgoCD -->|instala/atualiza| CP
        ArgoCD -->|instala| Registry
        ArgoCD -->|instala| MiniStack
        CP -->|provider-aws-s3 → Bucket| MiniStack
        CP -->|provider-helm → Release| spoke01
        CP -->|provider-helm → Release| spoke02
        ArgoCD -->|destination.name\n(chart/addon direto)| spoke01
        ArgoCD -->|destination.name\n(addon direto)| spoke02
    end

    Origin[("GitHub origin\n(backup/colaboração humana)")]
    DevLocal["Checkout local do operador"]
    DPRepo["Gogs: repo dataplanes\n(1 arquivo por cluster)"]

    DevLocal -->|push| Gogs
    DevLocal -->|push opcional| Origin
    DevLocal -->|push| DPRepo
    ArgoCD -->|ApplicationSet git-generator\nfiles| DPRepo
```

Observação: o diagrama mostra apenas o que existe hoje nos manifests
(`gitops/apps/*.yaml`, `gitops/appset/*.yaml`, `gitops/ministack/`, `gitops/registry/`). MiniStack é um componente recente
(commit `868d5ee`) que substitui/complementa qualquer necessidade de AWS real —
não há outro emulador AWS no repositório no momento.

## App-of-apps: da raiz aos componentes

A única `Application` aplicada manualmente é `gitops/root/app-of-apps.yaml`
(root-app-of-apps), que é `sources` múltiplo apontando para dois diretórios —
`gitops/apps/` (Applications simples) e `gitops/appset/` (ApplicationSets) —
cada um como fonte `directory`, com `exclude` para só considerar arquivos
`.yaml`/`.yml` (evita que subpastas não-Application quebrem a descoberta).
Toda `Application`/`ApplicationSet` filha vive num desses dois diretórios e é
descoberta automaticamente.

Filhas atuais, por `sync-wave` (menor primeiro):

| sync-wave | Application/ApplicationSet | Fonte | Namespace destino |
|---|---|---|---|
| `"0"` | `gogs` | `bootstrap/gogs` (directory) | `gogs` |
| `"0"` | `crossplane` | Helm chart oficial `charts.crossplane.io/stable` v1.20.13 | `crossplane-system` |
| `"0"` | `registry` | `gitops/registry/` (directory) | `registry` |
| `"0"` | `ministack` | `gitops/ministack/` (directory) | `ministack` |
| `"1"` | `crossplane-providers` | `gitops/crossplane/providers` (directory) | `crossplane-system` |
| `"1"` | `crossplane-compositions` | `gitops/crossplane/compositions/dataplane-cluster/chart` (helm) | `crossplane-system` |
| `"1"` | `crossplane-compositions-s3` | `gitops/crossplane/compositions/s3-bucket/chart` (helm) | `crossplane-system` |
| `"2"` | `crossplane-config` | `gitops/crossplane/config` (directory) | `crossplane-system` |
| `"2"` | `argocd-networking` | `gitops/argocd` (directory) | `argocd` |
| `"2"` | `dataplanes` (ApplicationSet) | git generator `files` (`dataplanes/*.yaml`) sobre o repo `dataplanes` | `argocd` (wrapper); filhas variam — spoke ou hub |
| `"2"` | `dataplane-addons` (ApplicationSet) | `matrix`: gerador `clusters` × git `directories` (`gitops/addons/*`) | direto no spoke (por addon) |
| `"2"` | `dataplane-dashboard` (ApplicationSet) | gerador `clusters`, filtrado por `lab.example.org/name: spoke-03` | direto no `spoke-03` (só ele) |

**Por que essa ordem:** Crossplane core precisa existir antes de qualquer
`Provider`/`ProviderConfig`/`Composition` que o referencie (wave 0 → 1); o
registry e o MiniStack também sobem na wave 0 porque as Compositions da wave 1
dependem deles ficarem prontos primeiro (a Function precisa da imagem já
publicável no registry; o `ProviderConfig ministack` referencia o MiniStack pelo
hostname do Service). `ProviderConfig`s (wave 2) só fazem sentido depois que o
`provider-kubernetes`/`provider-helm`/`provider-aws-s3` (wave 1, dentro de
`crossplane-providers`) já está instalado e healthy. O `ApplicationSet` de
dataplanes (wave 2) só funciona depois que a Composition `dataplane-cluster`
(wave 1) já registrou a XRD `XDataPlane` no cluster. Todas as filhas usam
`syncPolicy.automated.{prune,selfHeal}: true` e `CreateNamespace=true`
(Constitution Principle III), então a árvore inteira se autocorrige sem
intervenção manual.

## Papel do Crossplane (hub-and-spoke)

O Crossplane roda **somente no hub**. Suas Compositions produzem dois tipos de
efeito: (a) via `provider-kubernetes`, recursos `kubernetes.crossplane.io/v1alpha2`
`Object` aplicados **dentro** de um spoke já existente, usando o `ProviderConfig`
cujo nome bate com `spec.parameters.spoke`; (b) via `provider-helm`, um
`Release` que instala um chart **no próprio hub** — hoje só usado por
`dataplane-cluster` para trazer o spoke em si à existência. O Crossplane nunca
fala diretamente com a API de um spoke fora do `provider-kubernetes`.

Duas Compositions existem hoje (ver `docs/compositions.md` para detalhes de cada
uma):
1. `dataplane-cluster` — Patch-and-Transform clássico, cria o próprio spoke
   (um vcluster, via `provider-helm`) — não produz recursos *dentro* de um
   spoke, produz o spoke.
2. `s3-bucket` — Patch-and-Transform, provisiona um Bucket `provider-aws-s3` no
   MiniStack (não num spoke — é o único caso onde o alvo não é um cluster
   spoke, e sim o emulador AWS rodando no hub).

Uma terceira Composition, `dataplane-advanced` (Composition Function em Go,
`spec.mode: Pipeline`, produzia um conjunto mais rico de recursos **dentro**
de um spoke), existiu e foi removida por completo — ver ADR correspondente em
`docs/decisions.md`.

## Gogs como única fonte GitOps

ArgoCD reconcilia **exclusivamente** a partir do Gogs interno
(`http://gogs.gogs.svc.cluster.local:3000/...`), nunca do GitHub. Um remote
`origin` (GitHub) pode existir para colaboração/backup humano, mas o ArgoCD
nunca aponta para ele (Constitution: Development Workflow / Technology
Constraints). Isso mantém o lab funcional sem acesso à rede externa após o
bootstrap inicial.

Há dois repositórios Gogs relevantes:
- **`platform`** (este repositório) — tudo que ArgoCD instala diretamente vive
  sob `gitops/` (charts das Compositions, manifests do registry/MiniStack,
  Applications em `gitops/apps/`, ApplicationSets em `gitops/appset/`); o que
  é bootstrap puro (fora do Argo) vive sob `bootstrap/`.
- **`dataplanes`** — repositório separado: um arquivo `dataplanes/<spoke>.yaml`
  por cluster (charts + composition claims daquele spoke), mais os catálogos
  `charts/<nome>/chart/` (charts Helm aplicados direto num spoke) e
  `compositions/` (documentação do contrato de values de cada Composition
  instalada no hub). É consumido pelo `ApplicationSet` via git generator
  `files`.

## Registry OCI privado

> **Sem consumidor no momento**: este registry foi construído especificamente
> para hospedar a imagem da Composition Function `dataplane-advanced`, que foi
> removida do repositório. Continua rodando (nenhuma limpeza foi pedida), mas
> nada mais neste lab publica ou consome imagens dele hoje.

`gitops/registry/` sobe um `registry:2` (CNCF distribution/distribution) como
Deployment+PVC+Service+Ingress no hub, dedicado a publicar a imagem xpkg da
Composition Function. Pontos que fogem do "Deployment simples":
- **TLS é terminado pelo próprio pod do registry** (`REGISTRY_HTTP_TLS_*`),
  não pelo Ingress — o cliente `crossplane xpkg push`/pull do Crossplane exige
  HTTPS verificável na origem.
- **Service com ClusterIP fixo** (`10.43.0.50`, ver `gitops/registry/service.yaml`) —
  necessário porque o containerd do node não resolve `*.svc.cluster.local`
  (isso só resolve dentro do namespace de rede de um pod, via CoreDNS).
- **Exposto via `IngressRoute` do Traefik**, não `Ingress` puro — o provider
  Kubernetes-Ingress do Traefik v3 não respeitava o `scheme: https` do backend
  de forma confiável nos testes desta feature.
- Acesso externo: `https://registry.127-0-0-1.nip.io` (push manual pelo
  operador). Acesso interno (pull pelo cluster): via mirror de containerd
  configurado por `bootstrap/scripts/12-configure-hub-registry-mirror.sh`, que redireciona
  `registry.registry.svc.cluster.local:5000` para o ClusterIP fixo — ver
  `docs/decisions.md` para o porquê.

## MiniStack (emulador AWS local)

`gitops/ministack/` sobe o MiniStack (`ministack.org`, compatível com a API do LocalStack) como
Deployment+Service+PVC+Ingress no hub, mais um console web (`stackport`,
Deployment+Service próprios). É consumido pelo `provider-aws-s3` (Upbound,
v1.14.0) através do `ProviderConfig ministack`
(`gitops/crossplane/config/providerconfig-ministack.yaml`), que aponta para
`http://ministack.ministack.svc.cluster.local:4566` com credenciais falsas
(`skip_credentials_validation: true`, convenção universal de emuladores
estilo LocalStack). É o único componente do lab cujo alvo de provisionamento
não é um cluster spoke k3d.

Ambos os Deployments do MiniStack/StackPort levam `enableServiceLinks: false`
por precaução — o Floci (emulador anterior, ver ADR-025/ADR-026 em
`docs/decisions.md`) crashava de verdade porque o Kubernetes auto-injetava
`FLOCI_PORT=tcp://<ip>:4566` a partir do Service, colidindo com a própria
variável de config `FLOCI_PORT` do Floci. O MiniStack documenta `GATEWAY_PORT`
(não `MINISTACK_PORT`) como sua variável de porta, então o mesmo colisão não
foi confirmada — a flag ficou como precaução barata, não como correção de um
bug observado no MiniStack.
