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
  independente das outras, mas mantido na wave mais alta por convenção), o
  `ApplicationSet` `dataplanes` (precisa que a XRD `XDataPlane` já exista no
  cluster — o que só acontece depois que `crossplane-compositions` da wave 1
  sincronizou, já que o chart que ele dispara sempre emite a claim
  `DataPlane`), e o `ApplicationSet` `dataplane-addons` (precisa que pelo
  menos um spoke já esteja registrado no ArgoCD — o gerador `clusters` não
  produz nada até então).

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
compositions: []   # claims de Composition, aplicadas no hub (nenhuma
                    # composition com instance-chart disponível no momento)
```

Para cada arquivo, o `ApplicationSet` gera **uma Application "wrapper"**
(`dataplane-<spoke>`) **multi-source**:

1. **fonte 1** — este repositório (`platform`), caminho
   `charts/dataplane-cluster` (o chart que faz o fan-out — ver abaixo), com
   `helm.valueFiles: [$values/dataplanes/<spoke>.yaml]` — o próprio arquivo
   do spoke, lido como values do chart (seus campos batem 1:1 com
   `charts/dataplane-cluster/values.yaml`).
2. **fonte 2** — o repositório `dataplanes`, referenciado só como `ref: values`.

> **Nomes parecidos, coisas diferentes**: `charts/dataplane-cluster/` (este
> chart, wrapper/fan-out, existe desde ADR-029) e
> `compositions/dataplane-cluster/` (a Composition `XDataPlane` da feature
> 003, que cria o spoke em si) têm o mesmo nome-base por coincidência de
> nomenclatura — são artefatos completamente distintos, em pastas de topo
> diferentes (`charts/` vs `compositions/`).

Essa Application wrapper não cria recursos de workload diretamente: sempre
emite exatamente **uma claim `DataPlane`** (nomeada `{{ .Values.cluster }}`,
via `charts/dataplane-cluster/templates/dataplane-claim.yaml`, direto — não
como mais uma Application filha) e faz `range` sobre `.Values.charts` e
`.Values.compositions`, emitindo, para cada entrada, **uma Application filha
própria** (`dataplane-<spoke>-<nome>`) — o mesmo padrão de "Application
gerando Application" que já existia no `root-app-of-apps`, só que agora
parametrizado por dados vindos do Git em vez de arquivos fixos:

- a claim **`DataPlane`**: é o que traz o spoke em si à existência (feature
  003) — ver `docs/architecture.md`. Sempre emitida, mesmo que
  `charts`/`compositions` estejam vazios: um `dataplanes/<spoke>.yaml` com só
  `cluster: spoke-03` já é suficiente para um novo spoke nascer.
- entradas de **`charts`**: `destination.name: <spoke>` — endereça o
  Cluster do ArgoCD registrado por `scripts/16-register-argocd-clusters.sh`
  diretamente, sem Crossplane no meio. Fonte: o próprio repo `dataplanes`,
  caminho da entrada (`charts/<nome>`).
- entradas de **`compositions`**: `destination.server` é sempre o hub — o
  Crossplane só roda lá. Fonte: este repositório (`platform`), resolvida a
  partir do nome da composition via um mapa fixo em
  `charts/dataplane-cluster/templates/_helpers.tpl` — nenhuma composition
  mapeada no momento (a única que já esteve, `dataplane-advanced`, foi
  removida; qualquer entrada em `compositions:` falha explicitamente até uma
  nova composition com instance-chart ser adicionada ao mapa).
  O parâmetro `spoke` é injetado automaticamente a partir de `cluster:`.

**Fluxo ponta a ponta para provisionar um spoke novo do zero**:

```
1. Criar dataplanes/<spoke>.yaml — só "cluster: <nome>" já basta
2. git add / commit / push para o remote "gogs" do repo dataplanes
3. O ApplicationSet detecta o arquivo (git generator "files") e
   sincroniza a nova Application "dataplane-<spoke>"
4. Essa Application renderiza charts/dataplane-cluster, que emite:
   - a claim DataPlane <spoke> (sempre)
   - uma Application filha por entrada de charts/compositions (se houver)
5. A claim DataPlane vira um Release do provider-helm (compositions/
   dataplane-cluster), que instala o chart do vcluster no hub
6. scripts/16-register-argocd-clusters.sh registra o spoke novo
   (ProviderConfig + Cluster do ArgoCD) — passo manual, uma vez por spoke
7a. Application filha de "charts": Helm chart aplicado direto no spoke
    (destination.name), sem Crossplane
7b. Application filha de "compositions": renderiza um claim de uma
    composition mapeada em _helpers.tpl (nenhuma no momento) no hub; a
    Composition compõe os recursos reais como Objects do
    provider-kubernetes; provider-kubernetes aplica esses Objects no
    spoke indicado em "cluster:"
```

**Remover** uma entrada de `charts`/`compositions` remove só aquilo: a
Application filha correspondente é podada, cascateando a exclusão do
claim/recursos. Remover o arquivo `dataplanes/<spoke>.yaml` inteiro remove
tudo que aquele cluster tinha declarado — a Application wrapper, todas as
filhas, **e a claim `DataPlane`**, que por sua vez desprovisiona o vcluster
inteiro. Verificado de ponta a ponta duas vezes: na migração da estrutura
antiga (uma pasta por instância `adv-01`/`adv-03`) para esta (ADR-029), e na
migração de `spoke-01`/`spoke-02` de clusters k3d reais para vclusters
(feature 003) — incluindo os erros reais de templating pegos em cada uma
(YAML inválido por `{{ }}` não citado e parâmetro errado do gerador `files`
na primeira; RBAC do `provider-helm` e endereço de servidor do vcluster na
segunda — ver `docs/decisions.md`).

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

## O padrão `ApplicationSet` para `addons/` (instalado em todo spoke)

Diferente do padrão acima (um arquivo `dataplanes/<spoke>.yaml` editado por
spoke), o `ApplicationSet` `dataplane-addons`
(`gitops/apps/dataplane-addons-appset.yaml`) instala cada chart em
`addons/<nome>/` em **todo** spoke registrado no ArgoCD, sem nenhuma edição
por spoke. Usa um gerador `matrix` combinando:

1. `clusters`, com `selector.matchLabels: lab.example.org/role: dataplane` —
   sem esse filtro o gerador também traria o `in-cluster` implícito (o
   hub), onde nenhum addon de spoke faz sentido. O label é aplicado pelo
   mesmo `scripts/16-register-argocd-clusters.sh` que já cria o Secret do
   Cluster.
2. `git` `directories` sobre `addons/*`.

O produto cartesiano dos dois gera uma `Application`
(`dataplane-addons-<spoke>-<addon>`) por combinação, cada uma com
`destination.name: <spoke>` e `helm.valuesObject: {spoke: <spoke>}` — o
mesmo mecanismo `destination.name` que as entradas `charts:` já usam, só que
disparado automaticamente para todo spoke em vez de precisar de uma entrada
manual por spoke.

**Consequência prática**: adicionar `addons/<nome-novo>/` (um chart Helm
válido) faz com que ele apareça em todo spoke — existente ou futuro — no
próximo sync, sem tocar no `ApplicationSet` nem em nenhum
`dataplanes/<spoke>.yaml`. Remover a pasta remove o addon de todo spoke.

Um addon cujo `Ingress` precisa ser alcançável de fora do cluster (caso do
addon de exemplo `prometheus`) depende de `compositions/dataplane-cluster`
ligar `sync.toHost.ingresses: true` nos values do chart do vcluster — sem
isso, um `Ingress` criado dentro de um spoke não tem efeito nenhum (nenhum
controller de ingress roda dentro de um vcluster). Confirmado com um teste
manual (Deployment+Service+Ingress descartáveis dentro de `spoke-01`) antes
de qualquer addon existir: HTTP 200, depois HTTPS 200 com certificado
emitido pela `lab-ca-issuer` — o mesmo cert-manager/Traefik do hub, nunca
duplicado dentro do spoke.

## Fluxo de release de uma Composition (Makefile-driven)

Cada Composition em `compositions/<nome>/` expõe o mesmo alvo de Makefile:
`dev`, `build`, `push`, `test`, `clean`. O `Makefile` da raiz do repo itera
sobre `COMPOSITIONS := dataplane-cluster s3-bucket` — nenhuma das duas tem
imagem para publicar hoje (a única que tinha, `dataplane-advanced`, foi
removida junto com seu Go function-sdk-go/Dockerfile/xpkg build).

**Ambas** (`dataplane-cluster`, `s3-bucket`):
- `dev`/`build`: `helm lint` + `helm template` do chart (nenhuma imagem
  envolvida — `push` é um no-op).
- `test`: aplica um claim de exemplo contra o cluster real, espera
  `Ready`, confirma o estado, remove.

**Atalhos na raiz do repo**: `make build-all`/`push-all`/`release-all`/
`test-all`/`dev-all`/`clean-all` fazem fan-out sobre as duas Compositions;
`make build-<nome>`, `make test-<nome>`, etc. rodam um alvo único; `make
release-<nome>` é `build-<nome>` seguido de `push-<nome>`.

## Checklist mental de "minha mudança vai aparecer no cluster?"

1. O arquivo mudado está sob um caminho que alguma `Application`/
   `ApplicationSet` referencia (`gitops/apps/*.yaml` lista `source.path` ou
   `sources[].path` de cada uma)?
2. O commit foi enviado para o remote `gogs` (não só `origin`)?
3. Se for uma Composition com imagem: a imagem nova
   foi publicada no registry (`make push`/`release-<nome>`) **antes** de o
   `values.yaml` do chart referenciar a nova tag?
4. Se for uma instância de dataplane avançado: o diretório está no repo
   `dataplanes` (não neste repositório de plataforma), e o `ApplicationSet`
   já teve tempo de notar o diretório novo (ou os caches do ArgoCD foram
   reiniciados manualmente, se demorou demais)?
