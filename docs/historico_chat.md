# Histórico da conversa

> Este documento é uma reconstrução narrativa da sessão de chat que produziu
> este repositório, escrita por quem participou dela — não é uma transcrição
> literal mensagem-a-mensagem (a sessão foi longa demais e passou por várias
> compactações de contexto), mas cobre, em ordem cronológica, o que foi
> pedido, o que foi construído, e os incidentes reais encontrados pelo
> caminho. Para decisões técnicas isoladas em formato ADR, veja
> [`decisions.md`](decisions.md); este arquivo é sobre a jornada, não sobre
> conclusões isoladas.

## Fase 0 — Lab inicial (antes do início registrado desta sessão)

Antes do trecho coberto em detalhe por esta conversa, o lab já existia numa
forma inicial: três clusters k3d (`hub`, `spoke-01`, `spoke-02`) na mesma
rede Docker, ArgoCD em modo app-of-apps no hub, Gogs como fonte Git interna,
e uma primeira Composition Crossplane (Patch-and-Transform clássica) capaz
de provisionar `Namespace + Deployment + Service` num spoke escolhido. Essa
base é a feature `001-dataplane-provisioning`, documentada via spec-kit em
`specs/001-dataplane-provisioning/`.

## Fase 1 — Adoção do spec-kit

O operador pediu para o projeto passar a usar o GitHub Spec Kit
(`/speckit-*`) para desenvolvimento orientado a especificação. Isso gerou
`.specify/memory/constitution.md` (constitution v1.0.0, cinco princípios:
GitOps-only, isolamento hub-and-spoke, estrutura app-of-apps, Compositions
testáveis, segredos nunca commitados) e retroativamente documentou a feature
001 já implementada através do fluxo spec → plan → tasks.

## Fase 2 — HTTPS para ArgoCD e Gogs

Pedido: publicar o ArgoCD em `argocd.127-0-0-1.nip.io` com Let's Encrypt.
Isso disparou uma sequência de decisões que **mudou de direção no meio do
caminho**:

1. Primeira tentativa: Let's Encrypt de verdade (`letsencrypt-staging`/`prod`
   ClusterIssuers). O operador interrompeu e pediu para desfazer — sem DNS
   público apontando para o lab, challenges HTTP-01 reais nunca
   resolveriam; PowerShell rodando sem privilégios de admin já tinha negado
   uma tentativa de `choco install` mais tarde na sessão, então o ambiente
   também tinha essa limitação para automação adicional.
2. Segunda tentativa: HTTP puro, sem TLS.
3. Versão final: CA autoassinada interna via `cert-manager` (`ClusterIssuer`
   `selfsigned-ca` → `Certificate` `lab-ca` → `ClusterIssuer` `lab-ca-issuer`
   usado por todo o resto do lab desde então).

Depois disso veio uma rodada de depuração real, não hipotética:

- **Loop de redirect no ArgoCD**: o `argocd-server` atrás do Traefik
  redirecionava para `https://localhost:8080/` (o host que ele via na
  requisição, não o nip.io) — corrigido habilitando `server.insecure: true`
  no `argocd-cmd-params-cm` (Traefik já termina TLS; o backend fala HTTP).
- **Portas 80/443 do host**: k3d recriado com
  `-p 80:80@loadbalancer -p 443:443@loadbalancer` para expor o Traefik do
  hub diretamente no host Windows.
- **Certificado do registry mais tarde na sessão** teve um problema parecido
  quando o Traefik tentava falar HTTPS com o backend: resolvido com
  `IngressRoute` explícito (`scheme: https`) em vez de `Ingress` +
  anotações, depois de duas tentativas de anotação não surtirem efeito.

## Fase 3 — Feature 002: pipeline de Composition Function em Go

Pedido, em português, com bastante detalhe já na primeira mensagem: uma
Composition mais robusta escrita em Golang, hospedada no Gogs, um registry
privado para as imagens, um repositório próprio para declarações de
dataplanes (uma pasta por dataplane com `values.yaml`), e Helm sempre para
aplicar Compositions. O operador pediu explicitamente para seguir o fluxo
spec-kit completo e **não perguntar nada durante a execução** — então a
sessão rodou o ciclo inteiro autonomamente:

1. `/speckit-constitution` → v1.1.0 (permite Composition Functions em Go
   além do modelo P&T clássico, exige registry privado e entrega via Helm
   para toda Composition).
2. `/speckit-specify` → `specs/002-golang-composition-pipeline/spec.md`.
3. `/speckit-plan` → `plan.md`, `research.md`, `data-model.md`,
   `contracts/dataplane-instance-values.md`.
4. `/speckit-tasks` → 40 tasks em fases (Setup, Foundational, US1/US2/US3,
   Polish).
5. Implementação de ponta a ponta, com incidentes reais no caminho:

- **Registry privado**: `distribution/distribution` (`registry:2`) no hub.
  Precisou de TLS próprio (o `provider-kubernetes`/gerenciador de pacotes do
  Crossplane só busca imagens via HTTPS), `ClusterIP` fixo (o node do hub
  não resolve `*.svc.cluster.local` — isso só funciona dentro de pods, não
  no container do node/containerd) e um mirror de containerd
  (`scripts/12-configure-hub-registry-mirror.sh`) redirecionando o hostname
  amigável para esse IP fixo, com a CA registrada sob as duas chaves
  (hostname original e IP — containerd verifica TLS contra o endpoint que
  ele de fato conecta).
- **A CLI `crossplane`** precisou ser instalada manualmente
  (`crossplane xpkg build`/`push`) porque pacotes de Function do Crossplane
  são imagens OCI com metadata embutido, não imagens de runtime simples.
- **Bug real de prontidão**: a primeira versão da function nunca marcava
  `Ready` nos recursos compostos — diferente de Patch-and-Transform, um
  `Object` do `provider-kubernetes` composto via function não tem
  verificação de prontidão implícita. Corrigido com
  `Ready: resource.ReadyTrue` explícito, publicado como `v0.1.1` — esse
  bugfix acabou sendo, na prática, o teste real da User Story 2 (atualizar a
  function e republicar via Helm).
- **Colisão de nomes real**: os primeiros exemplos da Composition avançada
  usaram os mesmos nomes (`demo-01`/`demo-02`) dos exemplos da Composition
  baseline. Como as duas geram namespace `dp-<nome>` no spoke, a exclusão de
  um claim durante testes apagou os recursos do outro. Corrigido renomeando
  os exemplos avançados para `adv-*` e recriando os dois conjuntos do zero
  — ver ADR-019 em `decisions.md`.
- **Cache do ArgoCD**: depois de renomear/adicionar/remover pastas no repo
  `dataplanes`, o `ApplicationSet` continuava enxergando o estado antigo por
  vários minutos — Redis e o cache de listagem git do `repo-server`
  sobrevivem ao próprio timer de requeue do controller. Precisou de
  restart manual dos componentes (documentado como troubleshooting em
  `quickstart.md`).
- Ao final, o operador pediu para mover o código Go e o repositório
  `dataplane-function` planejado para **dentro deste mesmo repositório**
  (`function/`), abandonando a ideia original de um repo Gogs separado só
  para a function — o repo `dataplanes` (declarações de instância) continuou
  separado, por ser genuinamente uma fonte de verdade operacional distinta.

## Fase 4 — Organização em `compositions/`

Pedido: mover os projetos de Composition para uma pasta `compositions/` na
raiz, uma subpasta por Composition, cada uma com seu próprio Makefile
(dev/build/test), mais um Makefile raiz com um target para buildar e
publicar todas. Executado como um reorg puro (sem mudança de comportamento),
movendo `charts/dataplane-baseline` → `compositions/dataplane-baseline/chart`,
`charts/dataplane-advanced` + `function/` →
`compositions/dataplane-advanced/{chart,function,instance-chart}`, e
criando o Makefile raiz com `build-all`/`push-all`/`release-all`/`test-all`
e variantes por composition (`make release-dataplane-advanced` etc.).
`make` não está instalado neste ambiente Windows, então cada target foi
verificado rodando o comando interno equivalente na mão (helm lint/template,
go vet/build), não com `make` de verdade.

## Fase 5 — Erro de cache do ArgoCD reportado pelo usuário

O operador relatou o erro `error getting cached app managed resources:
cache: key is missing` ao tentar descrever recursos no ArgoCD — sintoma do
mesmo problema de cache já visto na fase anterior, mas agora afetando o
`application-controller`. Um restart resolveu o sintoma; o operador então
encontrou a issue `argoproj/argo-cd#15912` no GitHub e sugeriu
`redis.compression: none` como causa raiz — aplicado no
`argocd-cmd-params-cm`, com restart coordenado de todos os componentes que
falam com o Redis, eliminando a causa (divergência de compressão entre
componentes reiniciados de forma independente), não só o sintoma.

## Fase 6 — Acesso sem login no ArgoCD

Pedido: desligar o login do ArgoCD para o lab, sem usuário/senha fixo tipo
`admin/admin` — modo anônimo com role `admin` por padrão. Configurado via
`users.anonymous.enabled` (`argocd-cm`) e `policy.default: role:admin`
(`argocd-rbac-cm`), incorporado a `scripts/06-install-argocd.sh` para ser
reproduzível, e verificado com uma chamada de API real (`POST
.../sync`) sem nenhum header de autenticação.

## Fase 7 — Emulador AWS: Floci, depois MiniStack + StackPort

Pedido inicial: "adicione um floci no lab e faça uma composite pra criar um
s3 nele". "Floci" não era reconhecido de imediato — a sessão perguntou ao
operador antes de prosseguir (oferecendo MinIO/Garage/SeaweedFS como
alternativas mais conhecidas), já que construir uma peça inteira de infra
sobre um nome mal interpretado teria custo alto de retrabalho. O operador
confirmou: "floci mesmo, é um emulador de serviços da aws" — pesquisa web
confirmou o projeto real ([floci.io](https://floci.io)).

Implementado: `floci/` (Deployment+Service+Ingress, mais `floci-ui` como
console), `provider-aws-s3` (Upbound, v1.14.0) com `ProviderConfig` apontando
para o Floci, e a Composition `s3-bucket` (XRD `XS3Bucket`/claim
`S3Bucket`). Um bug real apareceu assim que testado: o Kubernetes injeta
`FLOCI_PORT=tcp://<ip>:4566` a partir do Service `floci`, que colide com a
própria variável de configuração do Floci e derruba o processo — corrigido
com `enableServiceLinks: false`. Verificado de ponta a ponta via API S3 real
(bucket default e com override de nome/região).

Pouco depois, em paralelo com o início da geração desta própria pasta
`docs/`, o operador pediu para trocar o Floci e o Floci-UI por **MiniStack**
(`ministackorg/ministack`) e **StackPort** (`davireis/stackport`) — troca
lateral, sem uma falha técnica registrada contra o Floci. A troca trouxe uma
vantagem real: o StackPort serve UI e API na mesma porta única (8080,
configurável só por env vars `AWS_ENDPOINT_URL`/credenciais), enquanto o
`floci-ui` tinha `localhost:4501` fixo no código do frontend e exigia um
script de port-forward dedicado para funcionar de verdade — problema que
deixa de existir com o StackPort. Durante a troca, um bug de "encontrado só
ao testar" apareceu: o comentário no topo da Composition `s3-bucket` foi
atualizado para "MiniStack", mas o `providerConfigRef.name: floci` de
verdade dentro do recurso ficou esquecido — o claim de teste continuou
tentando um `ProviderConfig` que não existia mais até o teste de ponta a
ponta expor o problema. Ver ADR-025/ADR-026 em `decisions.md` para os
detalhes técnicos dos dois.

## Fase 8 — Esta pasta `docs/`

Em paralelo com a troca Floci → MiniStack/StackPort, o operador pediu esta
pasta `docs/` com documentação de arquitetura, design e decisões — gerada
por um subagente com acesso só ao repositório (não a esta conversa), depois
revisada e com as referências ao Floci atualizadas para refletir a troca
para MiniStack/StackPort que aconteceu enquanto o subagente trabalhava. Este
arquivo (`historico_chat.md`) foi pedido logo em seguida, e escrito
diretamente por quem participou da conversa — o subagente da documentação
técnica não tinha (nem precisava ter) acesso a este histórico.
