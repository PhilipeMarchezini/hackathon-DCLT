# FinOps e estimativa de custos

## Governança

Todos os recursos suportados recebem `Project=SolidaryTech`, `Environment=Production`, `CostCenter=NGO-Core` e `ManagedBy=Terraform`. O dono deve ativar Cost Explorer, criar um AWS Budget mensal e revisar custos por tag semanalmente. Recursos do laboratório devem ser destruídos após a demonstração.

## Estimativa mensal de referência

Estimativa educacional para `us-east-1`, 730 h/mês, baixa carga e valores aproximados, sem impostos nem tráfego. Preços mudam; antes de uma aprovação financeira, refaça no AWS Pricing Calculator.

| Componente | Premissa | Aproximado USD/mês |
|---|---|---:|
| EKS control plane | 1 cluster | 73 |
| EC2 | 2 × `t3.medium` on-demand | 61 |
| RDS PostgreSQL | 2 × instância pequena, single-AZ + storage | 38 |
| ElastiCache | 1 node pequeno | 13 |
| Load Balancer | 1 LB + baixo LCU | 20 |
| EBS/ECR/S3/CloudWatch | baixo volume | 15 |
| DynamoDB/SQS | on-demand, baixo volume; uma réplica Global Table | < 5 |
| **Total indicativo** | laboratório ligado 24×7 | **≈ 225** |

New Relic é opcional e deve permanecer no limite gratuito. Prometheus, Grafana e Loki executam dentro dos nodes já contabilizados. PagerDuty Free e Discord não adicionam custo no cenário proposto.

## Otimizações implementadas

- Sem NAT Gateway no laboratório, evitando custo horário e processamento de dados.
- `t3.medium`, duas réplicas e limites de recursos dimensionados para demonstração.
- DynamoDB on-demand e SQS pagam por uso.
- ECR com lifecycle mantém apenas as imagens recentes.
- Logs locais com rotação e retenções curtas no ambiente de demonstração.
- HPA escala o hot path somente quando necessário.
- Tags habilitam showback por projeto/ambiente/centro de custo.
- O launch template do node group propaga as tags de FinOps para instâncias e volumes EBS. O control plane e serviços gerenciados continuam sujeitos às regras de tagging nativas de cada serviço.

## Produção real

O custo aumentaria ao adotar nodes privados, NAT/endpoints VPC, RDS Multi-AZ, Redis com réplica, armazenamento persistente de observabilidade, WAF, Route 53 e suporte. Savings Plans/Reserved Instances só devem ser considerados depois de medir uma linha de base de 30–60 dias. Spot é adequado para workloads tolerantes, não para toda a capacidade mínima do Donation.

## Desligamento do laboratório

Antes de destruir, exporte evidências e confirme os backups que precisam ser preservados:

```powershell
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```

O bucket de state possui proteção contra deleção acidental e pode exigir esvaziamento controlado depois que não houver mais necessidade acadêmica.
