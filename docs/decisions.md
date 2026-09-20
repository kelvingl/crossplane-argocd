# Decisões de arquitetura (log estilo ADR)

Log numerado de decisões técnicas reais tomadas ao longo deste projeto — não um
resumo idealizado. Inclui decisões que foram tentadas e depois revertidas ou
corrigidas, com o motivo real. As entradas 1–5 e 6–14 são derivadas
diretamente de `specs/001-dataplane-provisioning/research.md` e
`specs/002-golang-composition-pipeline/research.md` (mesmo conteúdo, não só um
link). As entradas seguintes vêm de commits e do `tasks.md` da feature 002, que
não têm um `research.md` correspondente.

Formato de cada entrada: **Decisão** / **Contexto** / **Racional** /
**Alternativas consideradas** / **Status**.

---

## Feature 001 — provisionamento hub-and-spoke

### ADR-001: `provider-kubernetes` como único mecanismo hub→spoke

**Decisão**: usar `crossplane-contrib/provider-kubernetes`, um `ProviderConfig`
por spoke (credenciais via `Secret` de kubeconfig) e recursos gerenciados
`Object` para criar manifests brutos no spoke alvo.

**Contexto**: o Crossplane roda só no hub (Constitution Principle II); é
preciso um jeito de provisionar recursos em outro cluster sem instalar
ferramentas de plataforma nele.

**Racional**: é o único mecanismo OSS genérico do Crossplane para gerenciar
recursos em um cluster *diferente* do que ele roda, sem depender de um recurso
comercial/enterprise. Mantém o hub como ponto de controle único e não exige
nada instalado no spoke.

**Alternativas consideradas**: recursos multi-cluster/"environments" do
Crossplane (não disponíveis na edição OSS); Cluster API (resolve ciclo de vida
de cluster, não provisionamento de workloads em um cluster já existente); uma
segunda instância de ArgoCD por spoke (violaria Principle II e duplicaria a
estrutura app-of-apps sem benefício).

**Status**: Aceito.

### ADR-002: Composition clássica (Patch-and-Transform), Crossplane v1.20.x

**Decisão**: fixar o Crossplane na linha v1.x mais recente e usar o modelo
clássico `spec.resources` (não XRs namespaced do v2, nem Composition
Functions) para a Composition baseline.

**Contexto**: a Composition de teste do hub-and-spoke precisava de um
mecanismo de composição para a primeira feature do lab.

**Racional**: mantém patches/`CombineFromComposite`/`FromCompositeFieldPath`
legíveis sem precisar de um runtime de function (ex.
`function-patch-and-transform`) como peça móvel extra, em um lab cujo
objetivo é ensinar o *padrão* hub-and-spoke, não o modelo de autoria mais novo
do Crossplane.

**Alternativas consideradas**: Crossplane v2 + Composition Functions — caminho
mais moderno, mas adiciona uma dependência de runtime de function e uma curva
de aprendizado maior; adiado para uma emenda de constituição deliberada e
futura em vez de adotado incidentalmente aqui (essa emenda de fato aconteceu
depois — ver ADR-006 em diante).

**Status**: Aceito (para a Composition baseline; ver ADR-006 para a
Composition avançada, que usa o modelo de Function).

### ADR-003: seleção de spoke como campo string simples, não label selector

**Decisão**: `spec.parameters.spoke` é copiado 1:1 para
`spec.providerConfigRef.name` em cada `Object` composto; nomes de
`ProviderConfig` são iguais aos nomes dos spokes (`spoke-01`, `spoke-02`).

**Contexto**: a claim precisa expressar "em qual spoke provisionar" de forma
simples de auditar.

**Racional**: determinístico e fácil de raciocinar para um lab de 2 spokes;
retargeting exige mudar exatamente um campo; adicionar um spoke não exige
mudar a Composition (ela nunca enumera nomes de spoke, só repassa a string
recebida).

**Alternativas consideradas**: `providerConfigRef` via `policy: Selector` por
label — mais flexível (ex. "qualquer spoke saudável na região X"), mas
adiciona indireção desnecessária agora; a migração para selector no futuro não
quebraria o contrato externo da XRD.

**Status**: Aceito.

### ADR-004: nomenclatura de namespace por claim via `CombineFromComposite`

**Decisão**: cada `Namespace`/`Deployment`/`Service` composto é
nomeado/namespaceado como `dp-<claim-name>` dentro do spoke alvo, calculado
com um patch `CombineFromComposite` sobre `metadata.name`.

**Contexto**: claims concorrentes contra o mesmo spoke não podem colidir.

**Racional**: garante isolamento entre claims concorrentes no mesmo spoke sem
exigir que o operador escolha um namespace manualmente.

**Alternativas consideradas**: namespace fixo (ex. sempre `dataplane-demo`) —
mais simples, mas duas claims contra o mesmo spoke colidiriam; rejeitado. (Uma
variante real desse risco de colisão apareceu depois entre *duas Compositions
diferentes* usando o mesmo nome de claim — ver ADR-019.)

**Status**: Aceito.

### ADR-005: reconciliação, não consistência imediata, resolve a ordem de apply

**Decisão**: os `Object`s de `Namespace`, `Deployment` e `Service` são
submetidos juntos, sem ordenação explícita; o `provider-kubernetes` tenta de
novo até o `Deployment`/`Service` poderem ser criados dentro do namespace
(ainda não existente).

**Contexto**: não há garantia de ordem de criação entre os três recursos
compostos.

**Racional**: o requisito era "a requisição continua tentando e converge", não
falhar permanentemente; introduzir `dependsOn` explícito entre recursos seria
cerimônia desnecessária para 3 recursos com um loop de reconciliação que
autocura em segundos.

**Alternativas consideradas**: gates de prontidão explícitos entre recursos
compostos — suportado pelo Crossplane, mas desnecessário aqui.

**Status**: Aceito.

---

## Feature 002 — pipeline de Composition Function em Go

### ADR-006: `function-sdk-go` (gRPC `RunFunction`) como runtime da Function

**Decisão**: implementar a lógica da composição avançada como um programa Go
usando o `function-sdk-go` do `crossplane-runtime`, que expõe um servidor gRPC
`RunFunction` chamado pelo runtime de function-pipeline do Crossplane a cada
reconcile.

**Contexto**: a constituição (amendment v1.1.0) passou a permitir Composition
Functions para novas Compositions mais avançadas.

**Racional**: é o único jeito suportado de escrever uma Composition Function
em Go; transforma "o que é composto" em código Go comum e testável em vez de
uma DSL YAML de patch-and-transform.

**Alternativas consideradas**: runtimes de function em KCL ou Python
(suportados pelo Crossplane, mas o requisito pedia Go explicitamente); embutir
a lógica direto no `provider-kubernetes` — impossível, o provider só aplica
manifests `Object`, não tem papel de composição/templating.

**Status**: Aceito.

### ADR-007: Composition aditiva — nova XRD, a existente permanece intocada

**Decisão**: publicar uma nova XRD `XDataPlaneAdvanced` / claim
`AdvancedDataPlane` (mesmo grupo de API `lab.example.org`) em vez de modificar
`XDataPlane`/`DataPlane` da feature 001 no local.

**Contexto**: a Constitution Principle IV exige que o exemplo da feature 001
continue verificado de ponta a ponta.

**Racional**: mudar o modo da Composition existente arriscaria regredi-la sem
benefício; uma segunda XRD também deixa a comparação "conjunto de recursos
mais rico" legível lado a lado no lab.

**Alternativas consideradas**: adicionar uma segunda `Composition`
(function-pipeline) para a *mesma* XRD `XDataPlane`, selecionada via
`compositionSelector` — tecnicamente possível no Crossplane v1.x, mas
complica o contrato da claim (qual Composition vence?) sem benefício real.

**Status**: Aceito.

### ADR-008: conjunto de recursos compostos mais rico, mesmo mecanismo de entrega

**Decisão**: a Function retorna o mesmo tipo de recursos compostos do exemplo
existente (Namespace, Deployment, Service, todos como `Object`s do
`provider-kubernetes` visando o spoke escolhido pela claim), mais um
`ConfigMap` e `resources.requests/limits` + labels/annotations padronizados no
Deployment.

**Contexto**: o requisito pedia uma Composition "mais rica" que a baseline,
sem mudar o mecanismo de entrega hub-and-spoke.

**Racional**: satisfaz o requisito sem mudar o mecanismo de entrega — a
Principle II (isolamento hub-and-spoke via `provider-kubernetes` +
`providerConfigRef.name`) se aplica igualmente a recursos compostos por
function e por patch-and-transform; a function só computa *quais* `Object`s
submeter, nunca fala com a API do spoke diretamente.

**Alternativas consideradas**: `HorizontalPodAutoscaler` — cogitado, adiado da
primeira versão para manter a function pequena e revisável; pode ser
adicionado depois sem mudar o contrato externo da claim.

**Status**: Aceito.

### ADR-009: registry privado = CNCF `distribution/distribution` (`registry:2`)

**Decisão**: rodar `registry:2` como Deployment+Service+PVC+Ingress no hub,
gerenciado via GitOps (`gitops/apps/registry.yaml`, sync-wave `"0"`), exposto
internamente em `registry.registry.svc.cluster.local:5000` e externamente em
`registry.127-0-0-1.nip.io`, reusando o padrão de Ingress+cert-manager já
comprovado para ArgoCD/Gogs.

**Contexto**: a imagem da Composition Function precisa ser publicada e puxada
de um registry privado, sem depender de um registry público externo
(Constitution Technology Constraints).

**Racional**: `distribution/distribution` é o registry OCI mais simples
possível — um único container, sem banco de dados — no mesmo estilo "uma peça
móvel por preocupação" que motivou escolher Gogs em vez de um forge mais
pesado.

**Alternativas consideradas**: Harbor — nível de produção (RBAC, scan de
vulnerabilidade, UI), pesado demais para o lab; zot — alternativa mais leve,
mas `distribution/distribution` é a implementação de referência mais
conhecida; `k3d --registry-create` — cria um container *fora* de qualquer
cluster k3d (um container Docker irmão), o que violaria a Principle I (não é
um objeto Kubernetes que o ArgoCD reconcilia) e a ideia de "estar no hub";
rejeitado a favor de um Deployment in-cluster.

**Status**: Aceito, com ajustes de implementação não previstos originalmente
— ver ADR-016, ADR-017 e ADR-018.

### ADR-010: empacotamento Helm para toda Composition, incluindo a pré-existente

**Decisão**: empacotar a XRD/Composition `XDataPlane`/`DataPlane` da feature
001 em um chart Helm mínimo (`compositions/dataplane-baseline/chart/`, hoje),
sem mudança de comportamento nos manifests renderizados, e trocar a fonte da
Application `crossplane-compositions` de `directory` para `helm`. A nova
Composition avançada já nasce como chart.

**Contexto**: a constituição foi emendada (v1.1.0) para exigir empacotamento
Helm de qualquer Composition instalada/atualizada pelo ArgoCD.

**Racional**: exigência direta da constituição emendada; envolver em vez de
reescrever os manifests existentes manteve o risco de regressão baixo — os
`templates/` do chart são o mesmo YAML, byte a byte, só movido para dentro de
um chart com um `values.yaml` inicialmente não usado.

**Alternativas consideradas**: deixar a Composition baseline em fonte
`directory` e só empacotar em Helm a nova — mais simples no curto prazo, mas
deixaria a emenda constitucional parcialmente aplicada; rejeitado.

**Status**: Aceito.

### ADR-011: repo `dataplanes` → um release Helm por diretório via `ApplicationSet`

**Decisão**: um novo `ApplicationSet` (`gitops/apps/dataplanes-appset.yaml`)
usa o gerador git `directories` sobre o repo Gogs `dataplanes` (uma entrada por
diretório de topo) para gerar uma `Application` ArgoCD por dataplane. Cada
Application gerada é **multi-source**: fonte 1 é o chart
`compositions/dataplane-advanced/instance-chart` deste repositório de
plataforma; fonte 2 é o diretório correspondente no repo `dataplanes`,
referenciado como `$values`.

**Contexto**: cada dataplane avançado deveria ser declarado como uma pasta
`values.yaml`, sem configuração manual de ArgoCD por instância.

**Racional**: é o padrão ArgoCD padrão para "chart vive no repo A, valores
vivem no repo B" (Applications multi-source, disponíveis desde ArgoCD 2.6);
satisfaz a descoberta automática e garante que adicionar a N-ésima dataplane
só toque seu próprio diretório — o template do `ApplicationSet` nunca muda.

**Alternativas consideradas**: uma `Application` ArgoCD estática por
dataplane, escrita à mão — exatamente a configuração manual por instância que
se queria evitar; gerador git *files* (um `config.json`/`values.yaml` por
arquivo, plano) em vez de *directories* — o requisito pedia literalmente "uma
pasta com o nome do dataplane"; colocar o chart dentro do próprio repo
`dataplanes` (Application single-source por diretório) — duplicaria o chart em
todo clone futuro do repo e exigiria um segundo `Repository` Secret do ArgoCD
para o mesmo conteúdo; rejeitado a favor do split multi-source.

**Status**: Aceito.

### ADR-012: código-fonte da Function e declarações de dataplane em repositórios
Gogs próprios — parcialmente revertido

**Decisão original**: dois repositórios Gogs novos e mínimos
(`dataplane-function`, `dataplanes`) hospedariam, cada um, só o que o
requisito atribuía explicitamente a eles. Tudo que o ArgoCD instala
diretamente (manifests do registry, os dois charts Helm, o `ApplicationSet`)
ficaria no repositório de plataforma.

**Racional original**: minimizar `Repository` Secrets novos do ArgoCD (dois,
não quatro) e evitar um problema de ovo-e-galinha em que o chart que instala o
`Function` precisaria viver no mesmo repo cujo único papel era hospedar código
Go não relacionado.

**Alternativas consideradas**: um único repo combinado para código da function
+ seu chart — exigiria um `Repository` Secret também para `dataplane-function`
(por causa do chart) e acoplaria o ciclo de vida de *empacotamento* da
function ao de *código-fonte* sem necessidade; rejeitado.

**O que de fato aconteceu**: durante a implementação, a pedido explícito do
operador, o código-fonte da Function **ficou neste mesmo repositório de
plataforma**, em `compositions/dataplane-advanced/function/` — não em um repo
Gogs `dataplane-function` separado (registrado como "Deviation 1" em
`specs/002-golang-composition-pipeline/tasks.md`). Só o repo `dataplanes`
(declarações por instância) permanece um repo Gogs autônomo, exatamente como
planejado.

**Status**: Parcialmente superado pela implementação real — o repositório
`dataplane-function` nunca foi criado; código da Function é parte deste
checkout, servido pelo Gogs (e também pelo `origin` do GitHub) como qualquer
outro arquivo da plataforma.

### ADR-013: sem autenticação no registry na v1

**Decisão**: o Service do registry não tem auth configurada; `docker
push`/`pull` contra `registry.127-0-0-1.nip.io` (certificado autoassinado, CA
já confiável para Gogs/ArgoCD) funciona diretamente da máquina do operador e
dos kubelets do cluster hub.

**Contexto**: autenticação/RBAC avançada do registry foi explicitamente
declarada fora de escopo pelo requisito.

**Racional**: como nenhuma credencial existe ainda, não há nada que possa ser
commitado acidentalmente (Constitution Principle V). Se auth for adicionada
depois, a credencial segue o mesmo padrão `.secrets/`/`Secret` já usado para
kubeconfigs de spoke.

**Alternativas consideradas**: auth básica via htpasswd desde o dia 1 — mais
realista, mas adiciona uma credencial para gerenciar sem benefício em um lab
de operador único.

**Status**: Aceito.

### ADR-014: build/publicação da imagem da Function é manual/scriptado, não CI

**Decisão**: `scripts/11-push-dataplanes-repo.sh` (e, hoje,
`compositions/dataplane-advanced/function/Makefile`) fazem `docker build &&
crossplane xpkg build && crossplane xpkg push` sob demanda, a partir da
máquina do operador. Nenhum webhook/pipeline de CI é conectado para
reconstruir a imagem a cada commit no código da Function.

**Contexto**: CI/CD foi explicitamente declarado fora de escopo do requisito.

**Racional**: construir infraestrutura de CI (um runner, um receptor de
webhook) seria uma feature própria, não parte deste lab.

**Alternativas consideradas**: webhook do Gogs → job de build in-cluster —
padrão real, genuinamente fora de escopo; deixado como feature futura
documentada, não tentado aqui.

**Status**: Aceito.

---

## Decisões e correções não documentadas em nenhum `research.md`

As entradas abaixo só existem nos commits e no `tasks.md` — não têm um
`research.md` correspondente, mas são decisões de engenharia tão reais quanto
as anteriores, incluindo incidentes.

### ADR-015: label estável `crossplane.io/claim-name` em vez do nome gerado da XR

**Decisão** (commit `c8dd3d7`): usar o label `crossplane.io/claim-name` como
fonte para nomear os recursos compostos no spoke, em vez do nome da XR gerado
pelo Crossplane (que é aleatório).

**Contexto**: nomear recursos pelo nome da XR (gerado, não determinístico)
tornava impossível prever/reconciliar o namespace/nome de um recurso a partir
só do nome da claim.

**Racional**: o nome da claim é o identificador estável e conhecido pelo
operador; o label `crossplane.io/claim-name` é preenchido automaticamente pelo
Crossplane em toda XR criada a partir de uma claim, então nenhuma lógica extra
é necessária para propagá-lo.

**Status**: Aceito. É o mecanismo usado por todas as três Compositions hoje
(`dp-<claim-name>`/`s3-<claim-name>`).

### ADR-016: registry termina TLS ele mesmo, com Service em ClusterIP fixo

**Decisão** (tasks.md T006/T007): o pod do registry termina TLS diretamente
(`REGISTRY_HTTP_TLS_CERTIFICATE`/`KEY`), e o Service usa um ClusterIP fixo
(`10.43.0.50`), não apenas um nome DNS.

**Contexto**: o gerenciador de pacotes do Crossplane só busca imagens via
HTTPS verificável; e o containerd do node do hub (que faz os pulls de imagem
disparados pelo kubelet) roda fora do namespace de rede de qualquer pod, então
não resolve `*.svc.cluster.local` — isso só resolve dentro de um pod, via
CoreDNS.

**Racional**: sem essas duas mudanças, o pull de imagem pelo node
simplesmente falha silenciosamente por não resolver o hostname.

**Alternativas consideradas**: nenhuma alternativa viável identificada para
o requisito de HTTPS verificável — apenas terminar TLS no backend em vez de
depender só do Ingress.

**Status**: Aceito.

### ADR-017: registry exposto via `IngressRoute` do Traefik, não `Ingress` puro

**Decisão** (tasks.md T008): usar um `IngressRoute` do Traefik
(`registry/ingress.yaml`) com `services[].scheme: https` explícito, em vez de
um `Ingress` padrão com annotations.

**Contexto**: o provider Kubernetes-Ingress do Traefik v3 não estava honrando
de forma confiável `appProtocol: https`/a annotation
`service.serversscheme` para esse backend, nos testes desta feature.

**Racional**: o `scheme: https` explícito do `IngressRoute` é inequívoco,
eliminando a ambiguidade que causava o problema.

**Status**: Aceito. Trouxe também `gitops/argocd/traefik-config.yaml`
(`HelmChartConfig` com `--serversTransport.insecureSkipVerify=true`), já que
o certificado de backend do registry não está na cadeia de confiança padrão
do Traefik.

### ADR-018: mirror de containerd no node do hub para pull do registry privado

**Decisão** (`scripts/12-configure-hub-registry-mirror.sh`, tasks.md T013a):
registrar um mirror `registries.yaml` no containerd do node
`k3d-hub-server-0`, redirecionando
`registry.registry.svc.cluster.local:5000` para o ClusterIP fixo do registry
(`10.43.0.50:5000`), confiando na CA do lab sob os dois nomes (hostname
original e IP).

**Contexto**: mesmo com o Service em ClusterIP fixo (ADR-016), o pull de
imagem feito pelo node (fora do namespace de rede de qualquer pod) continuava
sem conseguir resolver `*.svc.cluster.local`.

**Racional**: o mirror de containerd redireciona a referência de imagem no
nível do node, sem exigir que o cluster resolva DNS interno de fora de um
pod. A CA precisa estar registrada sob os dois nomes porque o cliente de
mirror do containerd verifica o TLS contra o endpoint que ele de fato conecta
(o IP), não contra o hostname original.

**Alternativas consideradas**: nenhuma alternativa sem esse mirror foi
encontrada — é um requisito estrutural de como o containerd do k3d resolve
pulls de imagem no nível do node.

**Status**: Aceito. Precisa ser reexecutado após recriar o cluster hub ou
rotacionar a CA.

### ADR-019: renomeação `demo-*` → `adv-*` após colisão real de namespace

**Decisão** (tasks.md, "Status note 2"): as instâncias de exemplo da
Composition avançada foram renomeadas de `demo-01`/`demo-02` para
`adv-01`/`adv-02`.

**Contexto/incidente real**: as duas Compositions (`dataplane-baseline` e
`dataplane-advanced`) renderizam o mesmo namespace `dp-<claim-name>` para um
dado nome de claim. Reusar os nomes de exemplo da baseline (`demo-01`/
`demo-02`) para a Composition avançada causou uma colisão real: quando as
claims avançadas de teste foram removidas (prune), os recursos do namespace
`dp-demo-01`/`dp-demo-02` pertencentes à Composition **baseline** foram
apagados junto.

**Racional**: renomear para um prefixo disjunto (`adv-*`) elimina a colisão
sem exigir nenhuma mudança de Composition — o problema era puramente de
nomenclatura de instância, não de design. Ambos os conjuntos de exemplos
(`demo-01`/`demo-02` da baseline, `adv-01`/`adv-02`/`adv-03` da avançada)
foram recriados do zero depois do incidente e verificados sem colisão.

**Status**: Aceito. É um lembrete operacional real, não hipotético: duas
Compositions que derivam nomes de recurso do mesmo jeito (`dp-<claim-name>`)
colidem se claims de Compositions diferentes usarem o mesmo nome.

### ADR-020: `Ready: resource.ReadyTrue` explícito nos `Object`s compostos pela Function

**Decisão** (`function/fn.go`, tasks.md T011): cada recurso desejado retornado
pela Function é marcado com `Ready: resource.ReadyTrue` explicitamente.

**Contexto/incidente real**: sem essa flag, a XR/claim `AdvancedDataPlane`
nunca reportava `Ready: "True"`, mesmo depois de todos os `Object`s
compostos já estarem sincronizados no spoke — descoberto porque a primeira
tentativa da US1 (feature 002) falhou em atingir `Ready`.

**Racional**: recursos `kubernetes.crossplane.io/v1alpha2` `Object` do
`provider-kubernetes` não recebem uma checagem de prontidão implícita da
forma que os recursos de uma Composition patch-and-transform clássica
recebem; uma function-pipeline precisa declarar a prontidão de cada recurso
explicitamente.

**Status**: Aceito. Foi corrigido junto com o release `v0.1.0` → `v0.1.1` da
imagem da Function (também serviu como o teste real da US2 — "atualizar a
function via Helm sem nada aplicado a mão").

### ADR-021: cache do ArgoCD (Redis + git-listing do repo-server) pode ficar
obsoleto além do requeue do ApplicationSet

**Observação operacional recorrente** (tasks.md T028/T037, quickstart.md
Troubleshooting): mudanças em diretórios do repo `dataplanes` (rename,
adição, remoção) às vezes não apareciam como Application nova/podada dentro
do requeue de 3 minutos do controller do `ApplicationSet` — observado duas
vezes durante a feature 002 (uma no rename `demo-*`→`adv-*`, outra ao remover
`adv-02`).

**Mitigação**: reiniciar manualmente `argocd-redis`, depois
`argocd-repo-server` e `argocd-applicationset-controller`, para forçar uma
releitura sem cache. Documentado como seção de Troubleshooting no
`quickstart.md` da feature 002.

**Status**: Mitigação manual aceita; não é um bug corrigido, é um
comportamento conhecido do ArgoCD que o operador precisa saber destravar.
Ver também ADR-023 (o efeito colateral dessas reinicializações manuais de
Redis).

---

## Rede, TLS e acesso às UIs (fora do escopo de qualquer feature-kit)

### ADR-022: HTTPS com Let's Encrypt tentado e abandonado a favor de CA
autoassinada interna

**Sequência real de commits**: `dbbeeee` (Configure ArgoCD TLS with Let's
Encrypt on nip.io domain) → `ec359b3` (Simplify ArgoCD access: use HTTP
Ingress for nip.io domains, remove Let's Encrypt/cert-manager) → `457d03e`
(port-forward + doc de acesso) → `fc8defb` (Enable HTTPS for ArgoCD and Gogs
with cluster-managed TLS certificates, CA autoassinada `lab-ca-issuer`) →
`d8457c5` (expor Traefik do k3d nas portas 80/443 do host) → `d560d15`
(`server.insecure=true` no ArgoCD, por estar atrás de um proxy que termina
TLS).

**Contexto**: o lab roda inteiramente local, sem DNS público apontando para
o host — challenges HTTP-01/DNS-01 do Let's Encrypt não têm como ser
validados de verdade contra um domínio `nip.io` resolvendo para
`127.0.0.1`/host local.

**Racional da reversão**: em vez de insistir em Let's Encrypt (que não tem
como emitir certificados de verdade nesse cenário), o lab foi simplificado
primeiro para HTTP puro (`ec359b3`), e depois evoluído para HTTPS de novo,
mas com uma CA interna autoassinada gerenciada pelo próprio cluster
(`lab-ca-issuer`, via cert-manager) — reobtendo HTTPS sem depender de emissão
de certificado público.

**Alternativas consideradas**: manter só HTTP (mais simples, mas menos
representativo de um ambiente real com TLS); Let's Encrypt staging (ainda
exige alcançabilidade pública, inviável para `127-0-0-1.nip.io` apontando
para um host local).

**Status**: Aceito no estado atual — HTTPS via CA autoassinada interna
(`lab-ca-issuer`), Traefik expõe as portas 80/443 do host, ArgoCD roda em
modo `insecure` internamente porque o TLS é terminado no proxy. A tentativa
com Let's Encrypt está superada, não removida do histórico — é a razão pela
qual a solução atual existe.

### ADR-023: acesso anônimo com role admin no ArgoCD, e desabilitação da
compressão do Redis

**Decisão A** (commit `d24a124`): `users.anonymous.enabled=true` no
`argocd-cm` e `policy.default=role:admin` no `argocd-rbac-cm` — qualquer
requisição (UI ou API) é tratada como admin, sem etapa de login.

**Contexto A**: o lab roda só local, sem exposição real; uma senha fixa
estilo admin/admin adiciona fricção sem adicionar segurança nesse contexto.
Dobrado em `scripts/06-install-argocd.sh` para ser reproduzível a partir de
um bootstrap limpo, não só um patch aplicado a um cluster já vivo. O README
documenta como reverter para acesso com login se necessário.

**Decisão B, efeito colateral real** (commit `249c0d0`): reiniciar
`argocd-redis` de forma independente dos outros componentes do ArgoCD (feito
repetidamente para destravar caches obsoletas do `ApplicationSet` — ver
ADR-021) deixou os componentes divergindo sobre compressão do valor
cacheado, causando o erro `error getting cached app managed resources: cache:
key is missing` (argoproj/argo-cd#15912). Corrigido com
`redis.compression: none` no `argocd-cmd-params-cm`, reiniciando todos os
componentes consumidores de Redis (server, repo-server,
applicationset-controller, application-controller) de uma vez — elimina a
divergência na origem, em vez de só limpar o sintoma a cada recorrência.

**Status**: Ambas aceitas e verificadas ao vivo (POST não autenticado de
sync retornou HTTP 200; GET de managed-resources voltou a retornar 200 sem
erro de cache em nenhum componente).

### ADR-024: reorganização de `charts/`/`function/` soltos para
`compositions/<name>/` autocontidos

**Decisão** (commit `7a4d277`): mover todo projeto relacionado a Composition
para `compositions/<name>/`, uma pasta por Composition, cada uma
autocontida com seu próprio `Makefile` (`dev`/`build`/`push`/`test`/`clean`).
Um `Makefile` na raiz do repo passa a orquestrar todas as Compositions com um
alvo uniforme (`build-all`/`push-all`/`release-all`/`test-all`, e variantes
`<alvo>-<nome>` por Composition).

**Contexto**: antes desta reorganização, os charts viviam soltos em
`charts/dataplane-baseline/`, `charts/dataplane-advanced/`,
`charts/dataplane-instance/`, e a Function em `function/` na raiz — sem
convenção clara de onde uma nova Composition deveria colocar seus arquivos.

**Racional**: uma pasta por Composition, com o mesmo target-surface de
Makefile em todas, torna trivial adicionar uma quarta/quinta Composition sem
inventar uma convenção nova a cada vez (confirmado logo em seguida pela
Composition `s3-bucket`, que já nasceu no formato novo).

**Status**: Aceito e verificado ao vivo — as três Applications/ApplicationSet
que referenciavam os caminhos antigos foram atualizadas e resincronizadas sem
outras mudanças. Nota de processo: `make` não estava disponível no ambiente
Windows/Git Bash usado para o desenvolvimento, então cada alvo foi validado
rodando o comando subjacente manualmente (`helm lint`/`template`, `go
vet`/`build`) em vez de `make` de verdade.

### ADR-025: Floci como emulador de AWS local, com `enableServiceLinks: false`
como pré-requisito

**Decisão** (commit `868d5ee`): adotar o Floci (floci.io), um emulador de
serviços AWS leve e compatível com LocalStack, como o novo componente
GitOps-gerenciado do hub (`floci/`) para exercitar S3 (e outras APIs "AWS")
inteiramente local — sem conta AWS real, sem custo.

**Racional**: mesmo raciocínio de "uma peça móvel simples" que já guiou
outras escolhas do lab (Gogs em vez de um forge pesado, `registry:2` em vez
de Harbor) — não há indicação no repositório de que um emulador AWS
diferente (ex. LocalStack) tenha sido avaliado a fundo; Floci foi a escolha
feita diretamente.

**Incidente real**: os dois Deployments do Floci (`floci`, `floci-ui`)
precisaram de `enableServiceLinks: false`. Sem essa flag, o Kubernetes
auto-injeta a variável de ambiente `FLOCI_PORT=tcp://<clusterIP>:4566` a
partir do Service `floci` em todo pod do namespace — que colide com a própria
variável de configuração `FLOCI_PORT` do Floci (que espera um inteiro, não
uma URL) e derruba o processo no boot.

**Status**: **Superado pelo ADR-026** — Floci foi substituído por MiniStack +
StackPort no mesmo dia, a pedido explícito do operador, sem uma razão técnica
registrada contra o Floci em si (ele funcionava). Verificado de ponta a ponta
antes da substituição (bucket criado com nome default e com override
explícito de `bucketName`/`region`, confirmados via API S3 do Floci, depois
desprovisionados) — a lição do `enableServiceLinks: false` continuou válida
para o substituto.

### ADR-026: Floci substituído por MiniStack (emulador) + StackPort (UI)

**Decisão** (commit a confirmar): trocar o par Floci/`floci-ui` por MiniStack
(`ministackorg/ministack`, mesmo protocolo LocalStack-compatível, porta 4566)
como emulador, e StackPort (`davireis/stackport`, porta 8080) como UI —
substituindo `floci/` por `ministack/` inteiro (namespace, Deployments,
Services, Ingress), renomeando o `ProviderConfig` do `provider-aws-s3` de
`floci` para `ministack`, e o secret de credenciais fake de
`floci-aws-credentials` para `ministack-aws-credentials`.

**Racional**: pedido direto do operador, sem justificativa técnica registrada
contra o Floci — ambos são emuladores AWS locais válidos; a troca é lateral,
não uma correção de defeito.

**Diferenças técnicas relevantes**:
- Persistência: MiniStack usa dois caminhos fixos dentro do container
  (`/tmp/ministack-state`, `/tmp/ministack-data/s3`) via `PERSIST_STATE=1` /
  `S3_PERSIST=1`, montados como `subPath`s do mesmo PVC — diferente do
  `FLOCI_STORAGE_PERSISTENT_PATH` único do Floci.
- `enableServiceLinks: false` foi mantido por precaução nos dois novos
  Deployments (ADR-025), mesmo o MiniStack documentando `GATEWAY_PORT` como
  sua variável de porta (não `MINISTACK_PORT`) — o risco de colisão com a
  variável Service-link injetada pelo Kubernetes é o mesmo tipo de bug, só
  que não confirmado como realmente disparado desta vez.
- **StackPort resolve o problema do ADR-025** (UI com porta hardcoded): ele
  serve UI e API na mesma porta única (8080) configurada só por
  `AWS_ENDPOINT_URL`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` via env vars
  — funciona normalmente atrás do Ingress `nip.io` padrão do lab, sem
  precisar de um script de port-forward dedicado como o `floci-ui` exigia.
- Um bug real foi pego e corrigido durante a troca: a `Composition` do
  `s3-bucket` teve seu comentário de topo atualizado para "MiniStack" mas o
  `providerConfigRef.name: floci` funcional ficou esquecido no `base` do
  recurso — o claim de teste continuou tentando usar um `ProviderConfig`/
  Secret que não existiam mais. Só apareceu ao testar de ponta a ponta, não
  na revisão do diff.

**Status**: Aceito, verificado de ponta a ponta com o mesmo roteiro do
ADR-025 (bucket default + bucket com override, confirmados via API S3 do
MiniStack).

---

### ADR-027: spoke-01/spoke-02 registrados como Clusters no ArgoCD

**Decisão**: criar um Secret por spoke no namespace `argocd`, com o label
`argocd.argoproj.io/secret-type: cluster` (formato declarativo padrão do
ArgoCD para registro de cluster), reaproveitando o mesmo kubeconfig
(client-cert/key, server via IP de container, TLS não verificado) já gerado
por `scripts/03-register-spokes.sh` para o `ProviderConfig` do
`provider-kubernetes`. Script novo: `scripts/16-register-argocd-clusters.sh`,
encadeado em `00-up.sh` logo após `06-install-argocd.sh`.

**Contexto**: até então o ArgoCD só "enxergava" o próprio hub
(`in-cluster`) — os spokes existiam como clusters k3d reais, mas eram
conhecidos apenas pelo Crossplane, através dos `ProviderConfig`s. O operador
pediu explicitamente que os dataplanes "fiquem registrados no argo como
clusters".

**Racional**: reaproveitar o kubeconfig já existente (em vez de gerar um
novo Secret/ServiceAccount `argocd-manager` como o `argocd cluster add`
faria) evita duplicar a superfície de credenciais dos spokes e mantém uma
única fonte de geração (`03-register-spokes.sh`) para "como o hub fala com
cada spoke". O `argocd` CLI foi descartado para essa tarefa porque exigiria
um fluxo de `login` incompatível com o acesso anônimo configurado no
ADR (ver seção "Rede, TLS e acesso às UIs"); o formato de Secret declarativo
é a forma oficialmente documentada de registrar um cluster sem o CLI.

**Escopo desta mudança**: só visibilidade/topologia. Nenhuma `Application`
do ArgoCD passou a apontar `destination.server`/`destination.name` para um
spoke — o provisionamento de recursos nos spokes continua 100% via
Crossplane/`provider-kubernetes`, como nas features 001/002. Registrar o
cluster no ArgoCD é o que faz `spoke-01`/`spoke-02` aparecerem em
Settings > Clusters na UI e habilita, se algum dia for necessário, uma
`Application` endereçada diretamente a um spoke — mas isso não foi pedido
nem implementado aqui.

**Secret não commitado**: como o Secret de kubeconfig do `provider-kubernetes`
(Constitution Principle V), o Secret de cluster do ArgoCD é criado
imperativamente pelo script, nunca versionado em Git.

**Status**: Superado pelo ADR-028 — o mecanismo de registro (de onde vem a
*lista* de spokes) mudou, mas o formato de Secret e a reutilização do
kubeconfig descritos aqui continuam valendo. Verificado, na época, via
`GET /api/v1/clusters` da API do ArgoCD
(sem header de autenticação, graças ao acesso anônimo do ADR de rede),
confirmando `spoke-01` e `spoke-02` listados ao lado do `in-cluster`.

---

### ADR-028: lista de clusters do ArgoCD passa a vir do repo `dataplanes`; Helm `lookup` descartado

**Decisão**: mover a *lista* de quais spokes registrar como Cluster do
ArgoCD para o repositório `dataplanes` — uma pasta `clusters/<spoke>/` por
spoke (mesma convenção das pastas de instância de dataplane, só que dentro
de `clusters/`), listada e aplicada por
`scripts/16-register-argocd-clusters.sh`, que agora clona o repo `dataplanes`
em vez de ter `spoke-01`/`spoke-02` hardcoded.

**Contexto**: pedido do operador logo após o ADR-027: "altera pra criar os
clusters no projeto de dataplanes no git". A primeira tentativa de
implementação foi **totalmente declarativa**: um `ApplicationSet`
(`dataplane-clusters`) lendo `clusters/*` do repo `dataplanes` via git
directories generator, renderizando um chart novo (`charts/argocd-cluster`)
que usava a função `lookup` do Helm para ler o kubeconfig do spoke *ao vivo*
do Secret já existente em `crossplane-system` — eliminando completamente a
necessidade de um script, e sem nenhuma credencial passando por `values.yaml`.

**Por que foi revertido**: testado de ponta a ponta (não só lido na
documentação do Helm) — o `ApplicationSet` gerou as duas `Application`s
corretamente, mas ambas ficaram com `sync: Unknown` e a mensagem de erro do
repo-server mostrava exatamente o comando executado:
`helm template . --name-template cluster-spoke-01 ... --include-crds`. O
repo-server do ArgoCD invoca o binário `helm template` para gerar manifests
de forma determinística/cacheável — e `helm template` (diferente de
`helm install`/`upgrade`) roda sem contexto de cluster, então `lookup`
sempre retorna um mapa vazio ali, mesmo com o Secret
`crossplane-system/spoke-01-kubeconfig` realmente existindo (confirmado com
`kubectl get secret` em paralelo, para descartar erro de digitação/RBAC). O
chart falhava com `fail(...)` no próprio template, de forma limpa, mas
continuava sendo um beco sem saída estrutural — não um bug de configuração
corrigível. `charts/argocd-cluster/` e o `ApplicationSet` foram removidos.

**Racional da correção**: como a criação do Secret de credenciais precisa
continuar imperativa de qualquer forma (Constitution Principle V — Secrets
Never Committed — nenhuma credencial pode ir para o `values.yaml` de um
chart em git), o único ganho real de "estar no Git" que ainda fazia sentido
buscar era a **lista de quais spokes registrar**, não o mecanismo de
aplicação. `scripts/16-register-argocd-clusters.sh` passou a clonar
`dataplanes.git` (mesmas credenciais/porta usadas por
`scripts/11-push-dataplanes-repo.sh`) e enumerar `clusters/*/` em vez de ter
os nomes dos spokes no próprio script — a fonte de verdade de "quais
clusters existem" ficou no Git, igual à fonte de verdade de "quais
dataplanes existem".

**Consequência prática**: o script deixou de ser encadeado em `00-up.sh`
(precisa que `scripts/11-push-dataplanes-repo.sh` já tenha criado o repo
`dataplanes` no Gogs) e passou a ser um passo manual documentado no
`README.md`, na mesma seção da composition avançada, logo depois do script
11.

**Status**: Aceito, verificado de ponta a ponta (Secrets `cluster-spoke-01`/
`cluster-spoke-02` recriados corretamente a partir do conteúdo do repo
`dataplanes`, confirmados via `GET /api/v1/clusters`).

---

## Resumo de decisões superadas ou com incidente associado

| ADR | O que mudou | Por quê |
|---|---|---|
| ADR-012 | Repo `dataplane-function` planejado nunca foi criado | Pedido explícito do operador durante a implementação |
| ADR-019 | Nomes de exemplo `demo-*` → `adv-*` | Colisão real de namespace entre duas Compositions |
| ADR-020 | Function passou a marcar `Ready` explicitamente | `provider-kubernetes` `Object`s não têm prontidão implícita |
| ADR-022 | Let's Encrypt → CA autoassinada interna | Sem DNS público alcançável para challenges reais |
| ADR-023 | Reinício isolado do Redis → compressão desabilitada | Divergência de cache entre componentes do ArgoCD |
| ADR-024 | `charts/`+`function/` soltos → `compositions/<name>/` | Falta de convenção para novas Compositions |
| ADR-025 | Floci + `floci-ui` → substituídos (ADR-026) | Pedido explícito do operador, sem defeito técnico |
| ADR-027 | Registro de clusters no ArgoCD: lista hardcoded → repo `dataplanes` (ADR-028) | Pedido explícito do operador |
| ADR-028 | `ApplicationSet`+Helm `lookup` descartado → script clonando o repo | `helm template` do repo-server do ArgoCD não tem acesso ao cluster |
