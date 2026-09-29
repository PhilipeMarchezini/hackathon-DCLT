[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot "..\terraform"),
    [string]$GitOpsRepository = ""
)

$ErrorActionPreference = "Stop"
$accountId = (aws sts get-caller-identity --query Account --output text).Trim()
if ($accountId -notmatch '^\d{12}$') { throw "Não foi possível obter o account ID da AWS." }

$veleroBucket = (terraform -chdir=$TerraformDirectory output -raw velero_bucket).Trim()
if ([string]::IsNullOrWhiteSpace($veleroBucket)) { throw "O output velero_bucket não está disponível." }
$awsRegion = (terraform -chdir=$TerraformDirectory output -raw aws_region).Trim()
if ($awsRegion -notmatch '^[a-z]{2}-[a-z]+-\d$') { throw "O output aws_region é inválido." }
$veleroBucketRegion = (terraform -chdir=$TerraformDirectory output -raw velero_bucket_region).Trim()
if ($veleroBucketRegion -notmatch '^[a-z]{2}-[a-z]+-\d$') { throw "A região do bucket Velero é inválida." }
if ([string]::IsNullOrWhiteSpace($GitOpsRepository)) {
    $GitOpsRepository = (terraform -chdir=$TerraformDirectory output -raw gitops_repository).Trim()
}
if ($GitOpsRepository -notmatch '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
    throw "gitops_repository deve ser uma URL HTTPS do GitHub para configurar o repository_dispatch."
}
$githubOwner = $Matches[1]
$githubRepository = $Matches[2]
$dispatchUrl = "https://api.github.com/repos/$githubOwner/$githubRepository/dispatches"

$gitopsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\gitops")).Path
Get-ChildItem (Join-Path $gitopsRoot "apps") -Filter "*-service.yaml" | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $content = $content -replace '(image:\s*)\d{12}\.dkr\.ecr\.[^.]+\.amazonaws\.com', "`${1}$accountId.dkr.ecr.$awsRegion.amazonaws.com"
    Set-Content -LiteralPath $_.FullName -Value $content -Encoding utf8
}

$appConfigMap = Join-Path $gitopsRoot "apps\configmap.yaml"
$content = Get-Content $appConfigMap -Raw
$content = $content -replace '(AWS_REGION:\s*)[^\r\n]+', "`${1}$awsRegion"
Set-Content -LiteralPath $appConfigMap -Value $content -Encoding utf8

$veleroManifest = Join-Path $gitopsRoot "platform\velero.yaml"
$content = Get-Content $veleroManifest -Raw
$content = $content.Replace("REPLACE_VELERO_BUCKET", $veleroBucket)
$content = $content -replace 'config:\s*\{ region: [^}]+ \}', "config: { region: $veleroBucketRegion }"
Set-Content -LiteralPath $veleroManifest -Value $content -Encoding utf8

$applicationsManifest = Join-Path $gitopsRoot "argocd\applications.yaml"
$content = Get-Content $applicationsManifest -Raw
$content = $content -replace '(repoURL:\s*)https://github\.com/[^/\s]+/[^\s]+', "`${1}$GitOpsRepository"
Set-Content -LiteralPath $applicationsManifest -Value $content -Encoding utf8

$observabilityManifest = Join-Path $gitopsRoot "observability\stack.yaml"
$content = Get-Content $observabilityManifest -Raw
$content = $content -replace '(repoURL:\s*)https://github\.com/[^/\s]+/[^\s]+', "`${1}$GitOpsRepository"
$content = $content -replace 'https://api\.github\.com/repos/[^/\s]+/[^/\s]+/dispatches', $dispatchUrl
Set-Content -LiteralPath $observabilityManifest -Value $content -Encoding utf8

Write-Host "GitOps renderizado para a conta $accountId, região $awsRegion, bucket $veleroBucket e repositório $GitOpsRepository. Revise e faça commit."
