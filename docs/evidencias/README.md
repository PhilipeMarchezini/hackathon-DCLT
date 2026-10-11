# Evidências da execução

Capturas do ambiente real provisionado na conta AWS Academy `713071293995`, em 11/10/2026.
Nenhuma imagem é simulada: todas vêm do cluster `solidarytech-production-eks` em operação, com
carga ativa gerada por `scripts/gerar-carga.ps1`.

## Capturadas

| Arquivo | Conteúdo | Requisito atendido |
|---|---|---|
| `01-actions-ci.png` | Pipeline verde do `donation-service` no commit `b8d2d15`, jobs `test-and-scan` e `publish-and-update-gitops` | Fase 3 — CI/CD com DevSecOps |
| `02-eks-nodes.png` | 3 nodes `Ready` em v1.35.8-eks com `MAX_PODS=110`, pods da plataforma, HPA e PDB | Fase 2 — Kubernetes e orquestração |
| `03-argocd.png` | 10 Applications `Synced` e `Healthy`, filtros confirmando `Synced 10` / `Healthy 10` | Fase 3 — GitOps |
| `04-api-smoke.png` | Jornada completa: `POST /ngos` 201, `POST /donations` 201 `APPROVED`, `POST /volunteers` 201, consulta pelo índice secundário, regras negativas 409 e 400, e a fila SQS | Fase 2 — os três data stores e o outbox |
| `05-sqs-outbox.png` | Fila principal e Dead Letter Queue, com `RedrivePolicy` e DLQ vazia | Fase 2 — mensageria |
| `06-grafana-slo.png` | Dashboard SRE: disponibilidade, error budget, latência ≤500ms, tráfego por status, p50/p95/p99, outbox pendente, CPU por pod e logs do Loki em tempo real | Fase 5 — SRE e Golden Metrics |
| `07a-newrelic-services.png` | Os três serviços em **Services - OpenTelemetry**, com response time, throughput e taxa de erro | Fase 4 e 5 — APM |
| `07b-newrelic-traces.png` | 9.100 traces agrupados por operação, com p95 por rota | Fase 4 e 5 — Distributed Tracing |
| `09-velero-backup.png` | Schedule de 6h, backup `Completed` com 724 itens e zero erros, `LocationConstraint: us-west-2` | Fase 5 — DR cross-region |
| `11-finops-tags.png` | Tags obrigatórias declaradas no Terraform e os recursos rastreados por `Project=SolidaryTech` | Fase 5 — FinOps |
| `12-hpa-scaling.png` | HPA escalando sob carga: `ngo-service` em 108%/70% com 6 réplicas, `volunteer-service` em 92%/70% com 4 | Fase 2 — escalabilidade |
| `13-govulncheck.png` | Pipeline reprovado pelo `govulncheck` em vulnerabilidades divulgadas no mesmo dia | Fase 3 — regra de bloqueio |

## Observação sobre a latência

O script de carga, executado do Brasil contra `us-east-1`, reporta p95 em torno de 330 ms. O p95
medido no servidor é de **6,88 ms** para `POST /donations`, visível em `07b-newrelic-traces.png`, e
de **8,4 ms** no Prometheus. A diferença é RTT de rede, não do serviço. O SLO de 500 ms é medido
server-side.

## Pendentes

Dois itens do checklist original não foram capturados porque dependem de cenários que ainda não
foram executados:

- **`08-alerta-incidente.png`** — a cadeia alerta → PagerDuty → Discord → self-healing está
  configurada e as três chaves foram validadas isoladamente, mas nenhum alerta real disparou. Exige
  provocar uma falha controlada até a regra de burn rate entrar em `Firing`.
- **`10-dr-restore.png`** — o backup está comprovado; o restore cronometrado ainda não foi
  executado.
