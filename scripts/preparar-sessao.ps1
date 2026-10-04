<#
.SYNOPSIS
    Prepara uma nova sessão do AWS Academy para provisionar a SolidaryTech.

.DESCRIPTION
    As credenciais do laboratório expiram a cada sessão e vários artefatos precisam ser
    recriados junto. Este script concentra tudo o que muda entre sessões:

      1. grava ~/.aws/credentials e ~/.aws/config
      2. valida as credenciais no STS e descobre o account ID
      3. cria e endurece os dois buckets S3 que o Terraform não consegue gerenciar
      4. gera uma senha nova para o banco
      5. escreve terraform/terraform.tfvars e terraform/backend.hcl
      6. atualiza os três secrets do GitHub usados pelo CI
      7. roda terraform init contra o backend remoto

    Os buckets ficam fora do Terraform porque um SCP da organização nega
    s3:GetBucketObjectLockConfiguration, chamada que o provider faz ao ler qualquer
    aws_s3_bucket depois de criá-lo. O recurso é criado, a leitura falha, e o apply
    seguinte entra em destrói-e-recria.

.PARAMETER CredentialsText
    O bloco colado da aba "AWS CLI" do AWS Academy, com as três linhas aws_*.
    Alternativa aos três parâmetros individuais.

.PARAMETER SkipGitHubSecrets
    Não atualiza os secrets do repositório. Útil se o gh não estiver autenticado.

.PARAMETER SkipTerraformInit
    Não executa o terraform init ao final.

.EXAMPLE
    .\scripts\preparar-sessao.ps1 -CredentialsText @'
    aws_access_key_id=ASIA...
    aws_secret_access_key=...
    aws_session_token=...
    '@

.EXAMPLE
    .\scripts\preparar-sessao.ps1 -AccessKeyId ASIA... -SecretAccessKey ... -SessionToken ...
#>
[CmdletBinding()]
param(
    [string]$CredentialsText = "",
    [string]$AccessKeyId = "",
    [string]$SecretAccessKey = "",
    [string]$SessionToken = "",
    [string]$Region = "us-east-1",
    [string]$DrRegion = "us-west-2",
    [string]$Repository = "PhilipeMarchezini/hackathon-DCLT",
    [switch]$SkipGitHubSecrets,
    [switch]$SkipTerraformInit
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$terraformDir = Join-Path $repoRoot "terraform"
$passwordFile = Join-Path $env:USERPROFILE ".solidarytech-db-password"

function Write-Step([string]$Text) { Write-Host "`n>>> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

# O PS 5.1 grava com BOM e lê com a codepage ANSI; fixe UTF-8 sem BOM nos arquivos
# que outras ferramentas leem.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Utf8Text([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

# O Windows PowerShell transforma cada linha de stderr de um executável nativo em
# ErrorRecord, o que dispara o ErrorActionPreference = Stop mesmo quando o comando
# termina com código 0. O AWS CLI escreve avisos em stderr rotineiramente, então
# as chamadas nativas passam por aqui: a preferência cai para Continue durante a
# execução e o sucesso é decidido por $LASTEXITCODE, não por $?.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        # Sem redirecionar stderr: é justamente o 2>&1 que cria o ErrorRecord.
        # O stderr vai direto ao console e o sucesso vem do código de saída.
        $output = (& $Command @Arguments) | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($null -eq $output) { $output = "" }
    return [pscustomobject]@{ ExitCode = $code; Output = $output.Trim() }
}

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    return Invoke-Native -Command "aws" @Arguments
}

# ---------------------------------------------------------------- 1. credenciais

Write-Step "Lendo credenciais"

if ($CredentialsText) {
    foreach ($line in $CredentialsText -split "`r?`n") {
        $i = $line.IndexOf("=")
        if ($i -lt 1) { continue }
        $key = $line.Substring(0, $i).Trim()
        $value = $line.Substring($i + 1).Trim()
        switch ($key) {
            "aws_access_key_id" { $AccessKeyId = $value }
            "aws_secret_access_key" { $SecretAccessKey = $value }
            "aws_session_token" { $SessionToken = $value }
        }
    }
}

if (-not $AccessKeyId -or -not $SecretAccessKey -or -not $SessionToken) {
    throw "Informe as três credenciais, por -CredentialsText ou pelos parâmetros individuais."
}
if ($AccessKeyId -notmatch '^[A-Z0-9]{16,}$') {
    throw "aws_access_key_id não parece válido: $AccessKeyId"
}

$awsDir = Join-Path $env:USERPROFILE ".aws"
if (-not (Test-Path $awsDir)) { New-Item -ItemType Directory -Path $awsDir | Out-Null }

Write-Utf8Text (Join-Path $awsDir "credentials") @"
[default]
aws_access_key_id = $AccessKeyId
aws_secret_access_key = $SecretAccessKey
aws_session_token = $SessionToken
"@
Write-Utf8Text (Join-Path $awsDir "config") @"
[default]
region = $Region
output = json
"@
Write-Ok "~/.aws/credentials e ~/.aws/config gravados"

# -------------------------------------------------------------------- 2. validar

Write-Step "Validando no STS"

$sts = Invoke-Aws sts get-caller-identity --output json
if ($sts.ExitCode -ne 0) { throw "STS recusou as credenciais:`n$($sts.Output)" }
$identity = $sts.Output | ConvertFrom-Json
$accountId = $identity.Account

Write-Ok "conta ..... $accountId"
Write-Ok "identidade  $($identity.Arn)"

$stateBucket = "solidarytech-tfstate-$accountId"
$veleroBucket = "solidarytech-production-velero-$accountId"

# --------------------------------------------------------------------- 3. buckets

Write-Step "Preparando os buckets fora do Terraform"

# O PowerShell remove as aspas duplas ao repassar um argumento para um executável
# nativo, e o AWS CLI recebe um JSON inválido. Gravar em arquivo e usar file://
# evita a questão de quoting por completo. Os parâmetros em shorthand (sem aspas)
# podem ir direto na linha de comando.
$jsonDir = Join-Path ([System.IO.Path]::GetTempPath()) ("solidarytech-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $jsonDir | Out-Null

$encryptionFile = Join-Path $jsonDir "encryption.json"
Write-Utf8Text $encryptionFile '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

$lifecycleFile = Join-Path $jsonDir "lifecycle.json"
Write-Utf8Text $lifecycleFile '{"Rules":[{"ID":"expire-old-backups","Status":"Enabled","Filter":{},"Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":30}}]}'

$publicBlock = "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
$tags = "TagSet=[{Key=Project,Value=SolidaryTech},{Key=Environment,Value=Production},{Key=CostCenter,Value=NGO-Core},{Key=ManagedBy,Value=AWS-CLI-SCP-workaround}]"

function Initialize-Bucket([string]$Name, [string]$BucketRegion, [bool]$WithLifecycle) {
    $head = Invoke-Aws s3api head-bucket --bucket $Name

    if ($head.ExitCode -ne 0) {
        if ($BucketRegion -eq "us-east-1") {
            $create = Invoke-Aws s3api create-bucket --bucket $Name
        }
        else {
            $create = Invoke-Aws s3api create-bucket --bucket $Name --region $BucketRegion `
                --create-bucket-configuration "LocationConstraint=$BucketRegion"
        }
        if ($create.ExitCode -ne 0) { throw "Falha ao criar o bucket ${Name}:`n$($create.Output)" }
        Write-Ok "$Name criado em $BucketRegion"
    }
    else {
        Write-Ok "$Name já existia"
    }

    $steps = @(
        @{ Nome = "versionamento"; Args = @("s3api", "put-bucket-versioning", "--bucket", $Name, "--versioning-configuration", "Status=Enabled") }
        @{ Nome = "criptografia"; Args = @("s3api", "put-bucket-encryption", "--bucket", $Name, "--server-side-encryption-configuration", "file://$encryptionFile") }
        @{ Nome = "bloqueio público"; Args = @("s3api", "put-public-access-block", "--bucket", $Name, "--public-access-block-configuration", $publicBlock) }
        @{ Nome = "tags FinOps"; Args = @("s3api", "put-bucket-tagging", "--bucket", $Name, "--tagging", $tags) }
    )
    if ($WithLifecycle) {
        $steps += @{ Nome = "lifecycle 30d"; Args = @("s3api", "put-bucket-lifecycle-configuration", "--bucket", $Name, "--lifecycle-configuration", "file://$lifecycleFile") }
    }

    foreach ($step in $steps) {
        # @variavel é splat; @(...) passaria o array inteiro como um só argumento.
        $stepArgs = $step.Args
        $result = Invoke-Aws @stepArgs
        if ($result.ExitCode -ne 0) { throw "Falha ao aplicar $($step.Nome) em ${Name}:`n$($result.Output)" }
    }
    Write-Ok "$Name endurecido"
}

try {
    Initialize-Bucket $stateBucket $Region $false
    Initialize-Bucket $veleroBucket $DrRegion $true
}
finally {
    Remove-Item $jsonDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------- 4. senha

Write-Step "Gerando a senha do banco"

# O RDS PostgreSQL recusa / " @ e espaço na senha master.
$alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#%*+-".ToCharArray()
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$databasePassword = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })

Write-Utf8Text $passwordFile $databasePassword
Write-Ok "salva em $passwordFile"

# ------------------------------------------------------------------ 5. tfvars

Write-Step "Escrevendo terraform.tfvars e backend.hcl"

Write-Utf8Text (Join-Path $terraformDir "terraform.tfvars") @"
aws_region        = "$Region"
dr_region         = "$DrRegion"
lab_role_name     = "LabRole"
gitops_repository = "https://github.com/$Repository.git"

# Um SCP da organizacao nega s3:GetBucketObjectLockConfiguration, chamada que o
# provider faz ao ler qualquer aws_s3_bucket apos cria-lo. Por isso os buckets sao
# criados pelo AWS CLI e apenas referenciados aqui.
create_dr_protection_resources = false
existing_velero_bucket_name    = "$veleroBucket"
existing_velero_bucket_region  = "$DrRegion"

# cluster_admin_principal_arns fica vazio de proposito: o Terraform deriva a role
# da sessao que esta aplicando e cria a access entry sozinho.
"@

Write-Utf8Text (Join-Path $terraformDir "backend.hcl") @"
bucket       = "$stateBucket"
key          = "solidarytech/production/terraform.tfstate"
region       = "$Region"
encrypt      = true
use_lockfile = true
"@
Write-Ok "ambos gravados (são ignorados pelo git)"

# ------------------------------------------------------------- 6. secrets GitHub

if ($SkipGitHubSecrets) {
    Write-Step "Secrets do GitHub ignorados por -SkipGitHubSecrets"
}
else {
    Write-Step "Atualizando os secrets do GitHub"
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warn "gh não encontrado; atualize os secrets manualmente."
    }
    else {
        $auth = Invoke-Native -Command "gh" auth status
        if ($auth.ExitCode -ne 0) {
            Write-Warn "gh não autenticado. Rode 'gh auth login' e repita o script."
        }
        else {
            $pairs = [ordered]@{
                AWS_ACCESS_KEY_ID     = $AccessKeyId
                AWS_SECRET_ACCESS_KEY = $SecretAccessKey
                AWS_SESSION_TOKEN     = $SessionToken
            }
            foreach ($name in $pairs.Keys) {
                # O valor vai por stdin para não aparecer na linha de comando.
                $previous = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $pairs[$name] | & gh secret set $name --repo $Repository | Out-Null
                    $code = $LASTEXITCODE
                }
                finally { $ErrorActionPreference = $previous }
                if ($code -eq 0) { Write-Ok "$name atualizado" } else { Write-Warn "falha ao gravar $name" }
            }
        }
    }
}

# ---------------------------------------------------------------------- 7. init

if ($SkipTerraformInit) {
    Write-Step "terraform init ignorado por -SkipTerraformInit"
}
else {
    Write-Step "Inicializando o Terraform"
    # Montado como array e passado por splat: argumentos iniciados por '-' soltos na
    # chamada são capturados pelo binder do PowerShell e chegam fora de ordem.
    $initArgs = @("-chdir=$terraformDir", "init", "-input=false", "-reconfigure", "-backend-config=backend.hcl")
    $init = Invoke-Native -Command "terraform" @initArgs
    if ($init.ExitCode -ne 0) { throw "terraform init falhou:`n$($init.Output)" }
    Write-Ok "backend remoto configurado em $stateBucket"
}

# --------------------------------------------------------------------- resumo

Write-Host "`n=== Sessão preparada ===" -ForegroundColor Green
Write-Host "Conta ............. $accountId"
Write-Host "Região ............ $Region (DR: $DrRegion)"
Write-Host "Bucket de state ... $stateBucket"
Write-Host "Bucket Velero ..... $veleroBucket"
Write-Host "Senha do banco .... $passwordFile"

Write-Host "`nPróximos passos:" -ForegroundColor Cyan
Write-Host @"
  `$env:TF_VAR_database_password = (Get-Content "$passwordFile" -Raw).Trim()
  terraform -chdir=terraform plan -out=tfplan
  terraform -chdir=terraform apply tfplan

  aws eks update-kubeconfig --region $Region --name solidarytech-production-eks
  .\scripts\render-gitops.ps1          # commite e faça push se houver alteração
  .\scripts\bootstrap-secrets.ps1 -DatabasePassword `$env:TF_VAR_database_password ``
      -NewRelicLicenseKey '<key>' -PagerDutyIntegrationKey '<key>' ``
      -DiscordWebhookUrl '<url>' -GitHubPat '<token>'

  gh workflow run ngo-service.yml       --repo $Repository --ref main
  gh workflow run donation-service.yml  --repo $Repository --ref main
  gh workflow run volunteer-service.yml --repo $Repository --ref main
"@
