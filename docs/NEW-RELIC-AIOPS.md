# Ativação do AIOps no New Relic Free

O envio OTLP já está preparado no OpenTelemetry Collector, mas a ativação do AIOps depende de uma conta externa e de uma `ingest license key`; nenhuma credencial é versionada. Este runbook transforma a integração opcional em uma configuração reproduzível e gera as evidências exigidas pela entrega.

## 1. Habilitar a ingestão

1. Criar uma conta New Relic Free e copiar a ingest license key.
2. Aplicar os secrets com `bootstrap-secrets.ps1 -NewRelicLicenseKey '<chave>'`.
3. Reiniciar os collectors e confirmar que não há erro de autenticação:

```powershell
kubectl rollout restart deployment/otel-collector -n observability
kubectl rollout restart daemonset/otel-logs -n observability
kubectl logs -n observability deployment/otel-collector --since=10m
```

4. Em **All entities**, validar `donation-service`, `ngo-service` e `volunteer-service`. Ajustar os nomes de atributos nas consultas abaixo caso a conta normalize a semântica OTLP de modo diferente.

## 2. Criar política e condições inteligentes

Criar a política `SolidaryTech-AIOps` e duas condições NRQL para a jornada `POST /donations`:

- `Donation - anomalia de latência`: condição do tipo **anomaly/baseline**, direção `upper only`, com janela deslizante de 5 minutos e criticidade após pelo menos 5 minutos fora da linha de base.
- `Donation - error budget`: condição estática de erro acima de 1% por 5 minutos. A condição de baseline complementa os limites SRE determinísticos; ela não substitui o SLO de 30 dias no Prometheus.

Consultas iniciais, a confirmar no Query Builder após a primeira ingestão:

```sql
SELECT percentile(duration.ms, 99)
FROM Span
WHERE service.name = 'donation-service'
  AND http.request.method = 'POST'
  AND http.route = '/donations'
```

```sql
SELECT percentage(count(*), WHERE http.response.status_code >= 500)
FROM Span
WHERE service.name = 'donation-service'
  AND http.request.method = 'POST'
  AND http.route = '/donations'
```

No recurso **Issues**, habilitar correlação/decisão inteligente para agrupar sinais da mesma entidade e reduzir ruído. Manter a automação destrutiva desabilitada: o New Relic detecta e correlaciona; Kubernetes/Argo CD executam somente as reconciliações já declaradas.

## 3. Workflow e teste

1. Criar um destino de notificação disponível na conta (Discord por webhook, PagerDuty ou outro canal aprovado).
2. Criar um workflow filtrando `policyName = SolidaryTech-AIOps` e anexar o destino.
3. Gerar carga controlada ou reduzir temporariamente o limite da condição em uma janela de teste.
4. Confirmar: sinal aberto, issue correlacionada, notificação recebida e normalização após cessar a anomalia.
5. Restaurar o limite original e guardar em `docs/evidencias/` os IDs/screenshots da entidade, condição, issue e notificação, sem expor chaves.

Sem conta/chave, Prometheus, Grafana e Loki continuam sendo a fonte operacional interna. Valores inertes criados pelo script para integrações não configuradas apenas permitem que o provisionamento do Grafana seja válido; eles não representam entrega externa bem-sucedida.

## Referências oficiais

- [Criar uma condição de alerta NRQL](https://docs.newrelic.com/docs/alerts/create-alert/create-alert-condition/create-nrql-alert-conditions/)
- [Detecção de anomalias](https://docs.newrelic.com/docs/alerts/create-alert/set-thresholds/anomaly-detection/)
- [Alertas e correlação por machine learning](https://docs.newrelic.com/docs/kubernetes-pixie/kubernetes-integration/installation/create-alerts/)
- [Tutorial de criação de alertas](https://docs.newrelic.com/docs/tutorial-create-alerts/create-an-alert/)
