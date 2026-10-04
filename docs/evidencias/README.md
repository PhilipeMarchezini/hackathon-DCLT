# Evidências da execução

Esta pasta recebe evidências reais depois do deploy no AWS Academy. Não substituir por imagens simuladas.

Checklist sugerido:

1. `01-actions-ci.png` — testes, scan e push aprovados.
2. `02-eks-nodes.png` — nodes Ready.
3. `03-argocd.png` — aplicações Synced/Healthy.
4. `04-api-smoke.png` — NGO, Donation e Volunteer respondendo.
5. `05-sqs-outbox.png` — evento publicado e backlog zerado.
6. `06-grafana-slo.png` — dashboard de SLI/SLO.
7. `07-logs-traces.png` — correlação no Loki/New Relic.
8. `08-alerta-incidente.png` — alerta e integração ITSM.
9. `09-velero-backup.png` — backup Completed.
10. `10-dr-restore.png` — restore validado e tempo medido.
11. `11-cost-explorer.png` — custos/tags.
12. `12-hpa-scaling.png` — `kubectl get hpa` e réplicas crescendo sob carga.

Para cada imagem, registrar data/hora, comando/cenário, resultado esperado e resultado obtido no relatório.
