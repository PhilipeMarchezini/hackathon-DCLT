# SolidaryTech — Hackathon DCLT

Plataforma de impacto social da ONG SolidaryTech, consolidando as entregas das fases 1 a 4 e a solução de DevOps/SRE da fase 5. O projeto está pronto para desenvolvimento local e para provisionamento no AWS Academy com Terraform, EKS, Argo CD, observabilidade e continuidade de negócio.

> O APM da entrega é o New Relic Free, alimentado por OTLP a partir do OpenTelemetry Collector. Datadog não é usado, pois a escolha entre as duas ferramentas é exclusiva. A stack de métricas e logs é Prometheus, Grafana e Loki.

## Arquitetura entregue

- `ngo-service` (Python/Flask + PostgreSQL): cadastro e consulta de ONGs.
- `donation-service` (Go + PostgreSQL + Redis + SQS): doações, cache e publicação confiável pelo padrão transactional outbox.
- `volunteer-service` (Python/Flask + DynamoDB): cadastro e busca de voluntários por ONG.
- Execução local reproduzível com Docker Compose, PostgreSQL, Redis, DynamoDB Local e LocalStack.
- AWS: VPC, EKS, ECR, RDS, ElastiCache, DynamoDB, SQS/DLQ, backup cross-region e S3 para Velero.
- GitOps com Argo CD, probes, HPA, PDB, NetworkPolicies e migrações idempotentes.
- CI/CD no GitHub Actions com testes, auditoria de dependências, scan de imagens e atualização declarativa do GitOps.
- SRE: métricas, logs e traces, SLO/error budget e alertas roteados para PagerDuty Free (ITSM), Discord (ChatOps) e GitHub Issues, com as chaves injetadas pelo `bootstrap-secrets.ps1`.

Detalhes: [arquitetura](docs/ARQUITETURA.md), [SRE](docs/SRE.md), [PCN/DR](docs/PCN-DR.md), [FinOps](docs/FINOPS.md), [ITSM/AIOps](docs/ITSM-AIOPS.md), [runbook New Relic AIOps](docs/NEW-RELIC-AIOPS.md) e [rastreabilidade](docs/RASTREABILIDADE.md).

## Rodar localmente

Pré-requisito: Docker Desktop com Compose v2.

```powershell
Copy-Item .env.example .env
docker compose up --build -d
docker compose ps
```

Smoke test:

```powershell
Invoke-RestMethod http://localhost:8081/health/ready
Invoke-RestMethod http://localhost:8082/health/ready
Invoke-RestMethod http://localhost:8083/health/ready

Invoke-RestMethod -Method Post http://localhost:8081/ngos -ContentType application/json -Body '{"name":"ONG Verde","email":"verde@example.org","cause":"Meio ambiente","city":"Sao Paulo"}'
Invoke-RestMethod -Method Post http://localhost:8082/donations -ContentType application/json -Body '{"ngo_id":1,"amount":50.00,"donor_name":"Doador Teste"}'
Invoke-RestMethod -Method Post http://localhost:8083/volunteers -ContentType application/json -Body '{"name":"Voluntario Teste","email":"voluntario@example.org","ngo_id":1}'
```

Remoção do ambiente local e dos volumes locais:

```powershell
docker compose down --volumes
```

## Provisionar no AWS Academy

As credenciais do Academy são temporárias. Atualize `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` e `AWS_DEFAULT_REGION=us-east-1` na sessão. O código reutiliza a role preexistente `LabRole` e não cria IAM Roles.

Antes do primeiro `apply`, publique este repositório no GitHub no endereço definido por `gitops_repository` (o padrão é `https://github.com/PhilipeMarchezini/hackathon-DCLT.git`) ou altere essa variável para o seu fork. O Argo CD precisa conseguir ler o repositório; a criação/publicação do fork é uma pré-condição externa e não é feita pelo Terraform.

```powershell
Copy-Item terraform/backend.hcl.example terraform/backend.hcl
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
$env:TF_VAR_database_password = '<senha-forte>'

terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
# Preencha bucket/key/region em backend.hcl com o output do bootstrap.
terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform apply tfplan

aws eks update-kubeconfig --region us-east-1 --name solidarytech-production-eks
.\scripts\render-gitops.ps1
.\scripts\bootstrap-secrets.ps1 -DatabasePassword $env:TF_VAR_database_password -NewRelicLicenseKey '<ingest-license-key>'
```

O script também renderiza todos os `repoURL`, o endpoint `repository_dispatch` e as URLs ECR para a região informada pelo Terraform. Em um failover, configure a variável de repositório `AWS_REGION` do GitHub para a região DR e execute `render-gitops.ps1` antes de sincronizar o Argo CD.

Revise e faça commit das substituições geradas por `render-gitops.ps1`. Depois construa as imagens iniciais executando manualmente os três workflows de serviço; a partir daí, o Argo CD acompanha o branch `main`.

Segredos do GitHub necessários para publicação no ECR: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN`. Como o token do Academy expira, eles devem ser atualizados a cada sessão.

Argo CD e Grafana não são expostos à internet. Acesso administrativo temporário:

```powershell
kubectl port-forward -n argocd svc/argocd-server 8443:443
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
```

## Demonstrar escalabilidade

Os três serviços têm `HorizontalPodAutoscaler` por CPU (alvo de 70%). Para gerar carga e evidenciar o escalonamento:

```powershell
.\scripts\gerar-carga.ps1 -BaseUrl http://<dns-do-load-balancer> -Service donation -WatchHpa
```

O script dispara requisições concorrentes com payloads válidos, imprime vazão, distribuição de status e latência p50/p95/p99, e registra `kubectl get hpa` antes, durante e depois. Use `-Service all` para alternar entre os três caminhos do Ingress, ou aponte `-BaseUrl` para `http://localhost:8082` e similares no ambiente local. O `scaleDown` tem janela de estabilização de 300 s, então as réplicas recuam alguns minutos após o fim da carga.

## API

| Serviço | Porta | Operações |
|---|---:|---|
| NGO | 8081 | `POST /ngos`, `GET /ngos`, `/health/live`, `/health/ready`, `/metrics` |
| Donation | 8082 | `POST /donations`, `GET /donations`, `/health/live`, `/health/ready`, `/metrics` |
| Volunteer | 8083 | `POST /volunteers`, `GET /volunteers/{ngo_id}`, `/health/live`, `/health/ready`, `/metrics` |

## Estrutura

```text
.
├── .github/workflows/       CI/CD, validação e self-healing
├── donation-service/        Serviço Go, outbox e testes
├── ngo-service/             Serviço Flask e testes
├── volunteer-service/       Serviço Flask/DynamoDB e testes
├── terraform/               IaC modular e bootstrap do state
├── gitops/                  Argo CD, workloads, plataforma e observabilidade
├── scripts/                 Inicialização local, bootstrap seguro e geração de carga
├── docs/                    Runbooks, evidências e relatório
└── docker-compose.yml       Ambiente local completo
```

## Entrega acadêmica

O relatório final está em [RELATORIO_FASE5.md](RELATORIO_FASE5.md) e [RELATORIO_FASE5.pdf](RELATORIO_FASE5.pdf). O PDF pode ser recriado com `python scripts/gerar-relatorio.py`. Evidências reais do deploy devem ser capturadas após a execução no laboratório e inseridas em `docs/evidencias/`; o repositório não apresenta screenshots simulados como execução real.

Autor: Philipe de Oliveira Marchezini — RM 369453.
