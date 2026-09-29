# Plano de Continuidade de Negócio e Disaster Recovery

## Objetivos e estratégia

| Escopo | Estratégia | RPO | RTO |
|---|---|---:|---:|
| Workloads Kubernetes | manifests no Git + Velero a cada 6 h em S3 `us-west-2` | 6 h | 4 h |
| Donation PostgreSQL | automated backups replicados para a região DR | 24 h | 4 h |
| NGO PostgreSQL | automated backups replicados para a região DR | 24 h | 4 h |
| DynamoDB | Global Table com PITR na região DR | assíncrono + janela PITR | 4 h |
| Imagens | código reproduzível + ECR primário | último SHA aprovado | 2 h |

O desenho é **pilot light**: backups e artefatos são preservados, mas um segundo EKS não permanece ligado. Isso é coerente com orçamento de ONG/AWS Academy e com RTO de quatro horas. Uma exigência de minutos demandaria warm standby e duplicaria parte relevante do custo.

## Critérios para declarar desastre

- Região primária indisponível sem previsão compatível com o RTO.
- Corrupção de dados que não possa ser corrigida por rollback/migração.
- Perda do cluster e falha de recriação dentro do tempo operacional esperado.

Somente o Incident Commander declara failover. Toda decisão deve registrar horário, evidência, ponto de restauração e responsáveis.

## Runbook de recuperação

1. Declarar P1, congelar deploys e registrar o timestamp-alvo do RPO.
2. Confirmar que o state Terraform, os automated backups RDS replicados, a Global Table e o bucket Velero estão acessíveis.
3. Criar um arquivo de variáveis DR com `aws_region=us-west-2`, `dr_region=us-east-1`, `manage_dynamodb_table=false`, `manage_ecr_repositories=false`, `create_dr_protection_resources=false` e `existing_velero_bucket_name=<bucket-do-primary>`. Use um backend/key diferente, por exemplo `solidarytech/production-dr.tfstate`.
4. Consultar os ARNs `auto-backup` na região DR com `aws rds describe-db-instance-automated-backups` e preencher `database_automated_backup_arns` para NGO e Donation. O módulo restaura cada RDS com `restore_to_point_in_time` e `use_latest_restorable_time`, sem tentar criar uma segunda Global Table, bucket ou regra de replicação.
5. Provisionar rede, EKS, RDS e serviços regionais com o state DR separado. O DynamoDB é lido como data source da Global Table existente.
6. Confirmar que os repositórios/imagens ECR foram replicados. A replicação só cobre conteúdo publicado depois de sua configuração; se algum SHA não existir, publicar novamente na região DR antes do rollout.
7. Configurar `AWS_REGION=us-west-2` nas variáveis do GitHub, executar `render-gitops.ps1`, revisar os manifests gerados e sincronizar o Argo CD.
8. Instalar Velero apontando para o bucket existente e restaurar namespaces; recriar secrets via `bootstrap-secrets.ps1` com os endpoints DR.
9. Executar smoke tests, comparar SLI e alterar DNS/endpoint somente após aprovação do Incident Commander.
10. Comunicar recuperação, monitorar 30 minutos e planejar failback. Não executar `terraform destroy` no state primário durante o failover.

Exemplo conceitual de restore Velero:

```powershell
velero backup get
velero restore create solidarytech-dr --from-backup <backup-aprovado> --wait
kubectl get pods -A
```

Exemplo de validação:

```powershell
kubectl get applications -n argocd
kubectl wait --for=condition=available deployment --all -n solidarytech --timeout=10m
Invoke-RestMethod https://<endpoint-dr>/donations
```

## Teste e evidência

- Trimestral: restore de Velero em namespace isolado.
- Semestral: restauração RDS e verificação de contagem/checksum.
- Anual: simulação completa de indisponibilidade regional e cronometragem de RTO/RPO.
- Guardar logs, timestamps, desvios e ações corretivas em `docs/evidencias/`.

O Terraform não tenta recriar recursos globais na segunda região: o state DR usa `manage_dynamodb_table=false`, reaproveita o bucket Velero e desliga a criação de KMS/replicação RDS. A configuração ECR cross-region é criada no state primário; novas imagens devem ser publicadas somente após essa regra estar ativa. Consulte a documentação AWS sobre [restauração PITR de automated backups replicados](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/AutomatedBackups.PiTR.html) e [replicação privada de imagens ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/replication.html).

## Failback

Recriar a região primária, sincronizar dados com janela de manutenção, testar, reduzir TTL do DNS, redirecionar tráfego e manter DR disponível até o fim do período de observação. Nunca restaurar por cima do único banco íntegro.
