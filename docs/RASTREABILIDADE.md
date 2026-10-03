# Rastreabilidade das entregas

| Fase/tema | Implementação | Evidência no repositório |
|---|---|---|
| Fase 1 — fundação da aplicação | Domínios de ONG, doação e voluntariado; APIs e persistência | `ngo-service/`, `donation-service/`, `volunteer-service/` |
| Fase 2 — containers e cloud | Dockerfiles multi-stage/non-root, composição local e serviços AWS | Dockerfiles, `docker-compose.yml`, `terraform/` |
| Fase 3 — Kubernetes e automação | EKS, manifests, HPA, probes, CI/CD e GitOps | `terraform/modules/eks`, `gitops/`, `.github/workflows/` |
| Fase 4 — operação/observabilidade | OTel, Prometheus, Grafana, Loki, métricas e dashboards | `gitops/observability/`, instrumentação nos serviços |
| Fase 5 — SRE | SLI/SLO/SLA, error budget, alertas e self-healing | `docs/SRE.md`, `sre-rules.yaml`, `self-healing.yml` |
| Fase 5 — FinOps | tags, sizing, lifecycle, forecast e teardown | `docs/FINOPS.md`, Terraform |
| Fase 5 — resiliência/PCN | outbox, DLQ, backup cross-region, Velero e DR | Donation, `terraform/modules/backup`, `docs/PCN-DR.md` |
| Fase 5 — ITSM/AIOps | classificação, integrações, correlação AIOps e ciclo de incidente | `docs/ITSM-AIOPS.md`, `docs/NEW-RELIC-AIOPS.md`, Grafana contact points |
| Entrega | documentação e área de evidências | `RELATORIO_FASE5.md`, `docs/evidencias/` |

## Critérios de aceite técnico

- `docker compose config --quiet` sem erro.
- Testes Python e Go aprovados.
- `terraform fmt -check -recursive` e `terraform validate` aprovados.
- `kubectl kustomize gitops/apps` renderiza todos os objetos.
- Nenhuma chave real ou senha versionada.
- Nenhuma dependência ou configuração Datadog.
- Após deploy: pods Ready, Argo CD Synced/Healthy, doação retorna 201, evento chega ao SQS, dashboards recebem telemetria e restore é testado.
