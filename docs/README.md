# Documentação

- [`architecture.md`](./architecture.md) — topologia hub-and-spoke, árvore app-of-apps do ArgoCD (com diagrama Mermaid), papel do Crossplane, Gogs, registry privado e MiniStack.
- [`compositions.md`](./compositions.md) — as três Compositions (`dataplane-baseline`, `dataplane-advanced`, `s3-bucket`): XRD/claim, o que cada uma compõe, empacotamento Helm e fluxo de Makefile.
- [`decisions.md`](./decisions.md) — log estilo ADR com as decisões técnicas reais do projeto (32 entradas), incluindo incidentes e reversões.
- [`gitops-workflow.md`](./gitops-workflow.md) — como uma mudança local chega a um recurso rodando: remotes, sync-waves, o `ApplicationSet` de dataplanes, e o fluxo de release das Compositions.
- [`historico_chat.md`](./historico_chat.md) — reconstrução narrativa da sessão de chat que produziu este repositório: o que foi pedido, em que ordem, e os incidentes reais encontrados pelo caminho.
