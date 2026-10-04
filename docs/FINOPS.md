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

New Relic opera no plano gratuito, cujo teto de 100 GB/mês de ingestão é suficiente para o volume da plataforma e mantém o custo de APM em zero. Prometheus, Grafana e Loki executam dentro dos nodes já contabilizados. PagerDuty Free e Discord não adicionam custo no cenário proposto.

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

Antes de destruir, exporte evidências e confirme os backups que precisam ser preservados.

Remova o Load Balancer antes do `destroy`. O Service do ingress-nginx cria um Classic Load Balancer
que o Terraform não gerencia, e as ENIs dele travam a deleção do internet gateway e da VPC por
dezenas de minutos. Apagar as Applications do Argo CD não resolve, porque sem o finalizer
`resources-finalizer.argocd.argoproj.io` os recursos permanecem; e o cloud controller não remove o
balanceador sozinho com as permissões da LabRole.

```powershell
$elb = aws elb describe-load-balancers --query 'LoadBalancerDescriptions[0].LoadBalancerName' --output text
$vpc = aws elb describe-load-balancers --query 'LoadBalancerDescriptions[0].VPCId' --output text
aws elb delete-load-balancer --load-balancer-name $elb

terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```

Se o destroy parar em `aws_vpc ... Still destroying`, o culpado é o security group `k8s-elb-*` que
sobrou do balanceador. Remova-o em outro terminal e a deleção prossegue:

```powershell
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=k8s-elb-*" --query 'SecurityGroups[].GroupId' --output text
aws ec2 delete-security-group --group-id <id>
```

O bucket de state possui proteção contra deleção acidental e pode exigir esvaziamento controlado depois que não houver mais necessidade acadêmica.
