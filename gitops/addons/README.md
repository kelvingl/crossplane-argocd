# addons

Cada pasta aqui é `<nome>/chart/` — um chart Helm instalado, **automaticamente,
em todo spoke registrado no ArgoCD**, pelo `ApplicationSet` `dataplane-addons`
(`gitops/appset/dataplane-addons-appset.yaml`) — um `matrix` generator
combinando o gerador `clusters` (filtrado por
`lab.example.org/role: dataplane`, para não incluir o `in-cluster`/hub) com
um gerador `git` `directories` sobre `gitops/addons/*`. O resultado é uma
`Application` por combinação (spoke × addon), cada uma com
`destination.name: <spoke>` — instalada direto no spoke, sem Crossplane no
meio, mesmo mecanismo que as entradas `charts:` de `dataplanes/<spoke>.yaml`
já usam.

Cada chart recebe `spoke: <nome-do-spoke>` automaticamente (`valuesObject`
no template do `ApplicationSet`) — use isso para montar hostnames/domain
filters específicos do spoke.

Adicionar um addon novo = criar `<nome>/chart/` (Chart.yaml + `templates/`,
com as definições dos recursos em `templates/definitions/`) com um chart Helm
válido; ele aparece em todo spoke (existente ou futuro) no próximo sync, sem
editar o `ApplicationSet`.

## Addons de exemplo

- **`prometheus/`** — servidor Prometheus com sua UI web, exposta em
  `https://prometheus.<spoke>.127-0-0-1.nip.io` (TLS via `lab-ca-issuer`,
  igual às outras UIs do lab). O `Ingress` é criado **dentro** do spoke; só
  fica alcançável de fora porque `gitops/crossplane/compositions/dataplane-cluster`
  liga `sync.toHost.ingresses` no chart do vcluster — o objeto é sincronizado
  para o hub, onde o Traefik e o cert-manager de verdade (nenhum dos dois
  roda dentro de um spoke) o enxergam.
- **`external-dns/`** — demonstra o padrão external-dns: observa `Ingress`
  em cada spoke (`domain-filter: <spoke>.127-0-0-1.nip.io`), provider
  `inmemory` (o provedor oficial do próprio projeto para testes — nip.io já
  resolve qualquer subdomínio sozinho, não existe um DNS real para gerenciar
  aqui). Ver os logs do pod para acompanhar a reconciliação.
