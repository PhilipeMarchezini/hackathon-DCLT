# Estratégia SRE

## Jornada crítica e indicadores

A jornada crítica é criar uma doação em `POST /donations`. Sucesso técnico é resposta não-5xx; sucesso de desempenho é resposta em até 500 ms. O evento pode chegar mais tarde ao SQS porque sua durabilidade é garantida pelo outbox.

| Conceito | Definição |
|---|---|
| SLI de disponibilidade | `1 - (requisições 5xx / requisições totais)` no Donation |
| SLO interno | 99,9% de respostas não-5xx em janela móvel de 30 dias |
| SLI de latência | proporção de requisições com duração ≤ 500 ms |
| SLO de latência | 99% em até 500 ms em 30 dias |
| SLA externo proposto | 99,5% mensal para processamento de doações |
| Error budget | 0,1% das requisições ou cerca de 43m49s de indisponibilidade/mês |

Os recording rules e alertas estão em `gitops/observability/manifests/sre-rules.yaml`; o dashboard está em `dashboards.yaml`. O alerta de erro dispara quando 5xx supera 1% por 5 minutos. Também existem alertas de p95, backlog do outbox e consumo acelerado do error budget.

## Política de error budget

- Consumo abaixo de 50%: releases normais.
- Entre 50% e 100%: reduzir mudanças de risco e priorizar itens de confiabilidade.
- Budget esgotado: congelar features do hot path; somente correções, segurança e redução de risco até recuperação da janela.
- Exceções precisam de decisão registrada com responsável e rollback.

## Observabilidade

- Métricas: Prometheus faz scrape dos três serviços e do collector.
- Logs: JSON em stdout, coletado pelo OTel Collector DaemonSet e enviado ao Loki.
- Traces: instrumentação OpenTelemetry nos serviços; exportação para o collector.
- Visualização/alertas: Grafana Unified Alerting (com regras Prometheus para avaliação e visibilidade). Exportação OTLP e correlação AIOps são opcionais no New Relic Free; o procedimento está em `docs/NEW-RELIC-AIOPS.md`.
- Incidentes: contact points opcionais para PagerDuty Free, Discord e GitHub dispatch.
- Datadog: deliberadamente ausente, pois não existe assinatura ativa.

## Operação e MTTR

O Argo CD autocorrige drift e o Kubernetes reinicia containers, refaz pods e redistribui réplicas. O workflow `self-healing.yml` audita o estado a cada 15 minutos, força refresh do Argo CD e abre issue quando detecta workload anormal.

Meta operacional: reconhecer P1 em até 10 minutos, mitigar em até 60 minutos e produzir post-mortem sem culpabilização em até 2 dias úteis. MTTR é medido de `incident.created_at` até `service.restored_at`; MTTD, do primeiro sintoma até o primeiro alerta.

## Runbook de incidente P1

1. Reconhecer alerta e declarar incidente no canal `#incidentes`.
2. Verificar dashboard SRE, logs correlacionados e estado do Argo CD.
3. Confirmar impacto com `kubectl get pods -n solidarytech` e probes externas.
4. Mitigar: rollback GitOps para a tag anterior, escalar réplicas ou desabilitar mudança causadora.
5. Se dados/região forem a causa, executar o runbook [PCN/DR](PCN-DR.md).
6. Validar SLI por pelo menos 15 minutos, encerrar e abrir post-mortem.

Comandos úteis:

```powershell
kubectl get applications -n argocd
kubectl get pods,hpa,pdb -n solidarytech
kubectl logs -n solidarytech deploy/donation-service --since=15m
kubectl rollout status -n solidarytech deploy/donation-service
kubectl rollout undo -n solidarytech deploy/donation-service
```

O `rollout undo` serve como mitigação emergencial. A correção permanente deve reverter o manifesto no Git, evitando que o Argo CD reaplique a versão defeituosa.
