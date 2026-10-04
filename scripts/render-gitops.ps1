[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot "..\terraform"),
    [string]$GitOpsRepository = ""
)

$ErrorActionPreference = "Stop"

# O Windows PowerShell 5.1 lê com a codepage ANSI e o -Encoding utf8 do
# Set-Content grava com BOM. A combinação corrompia os acentos dos manifests
# (Serviço virava ServiÃ§o) e inseria BOM em todo YAML renderizado. Estas duas
# funções fixam UTF-8 sem BOM na leitura e na escrita.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Read-Utf8Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
function Write-Utf8Text([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

$accountId = (aws sts get-caller-identity --query Account --output text).Trim()
if ($accountId -notmatch '^\d{12}$') { throw "Não foi possível obter o account ID da AWS." }

$veleroBucket = (terraform "-chdir=$TerraformDirectory" output -raw velero_bucket).Trim()
if ([string]::IsNullOrWhiteSpace($veleroBucket)) { throw "O output velero_bucket não está disponível." }
$awsRegion = (terraform "-chdir=$TerraformDirectory" output -raw aws_region).Trim()
if ($awsRegion -notmatch '^[a-z]{2}-[a-z]+-\d$') { throw "O output aws_region é inválido." }
$veleroBucketRegion = (terraform "-chdir=$TerraformDirectory" output -raw velero_bucket_region).Trim()
if ($veleroBucketRegion -notmatch '^[a-z]{2}-[a-z]+-\d$') { throw "A região do bucket Velero é inválida." }
if ([string]::IsNullOrWhiteSpace($GitOpsRepository)) {
    $GitOpsRepository = (terraform "-chdir=$TerraformDirectory" output -raw gitops_repository).Trim()
}
if ($GitOpsRepository -notmatch '^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$') {
    throw "gitops_repository deve ser uma URL HTTPS do GitHub para configurar o repository_dispatch."
}
$githubOwner = $Matches[1]
$githubRepository = $Matches[2]
$dispatchUrl = "https://api.github.com/repos/$githubOwner/$githubRepository/dispatches"

$gitopsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\gitops")).Path
Get-ChildItem (Join-Path $gitopsRoot "apps") -Filter "*-service.yaml" | ForEach-Object {
    $content = Read-Utf8Text $_.FullName
    $content = $content -replace '(image:\s*)\d{12}\.dkr\.ecr\.[^.]+\.amazonaws\.com', "`${1}$accountId.dkr.ecr.$awsRegion.amazonaws.com"
    Write-Utf8Text $_.FullName $content
}

$appConfigMap = Join-Path $gitopsRoot "apps\configmap.yaml"
$content = Read-Utf8Text $appConfigMap
$content = $content -replace '(AWS_REGION:\s*)[^\r\n]+', "`${1}$awsRegion"
Write-Utf8Text $appConfigMap $content

$veleroManifest = Join-Path $gitopsRoot "platform\velero.yaml"
$content = Read-Utf8Text $veleroManifest
$content = $content.Replace("REPLACE_VELERO_BUCKET", $veleroBucket)
$content = $content -replace 'config:\s*\{ region: [^}]+ \}', "config: { region: $veleroBucketRegion }"
Write-Utf8Text $veleroManifest $content

$applicationsManifest = Join-Path $gitopsRoot "argocd\applications.yaml"
$content = Read-Utf8Text $applicationsManifest
$content = $content -replace '(repoURL:\s*)https://github\.com/[^/\s]+/[^\s]+', "`${1}$GitOpsRepository"
Write-Utf8Text $applicationsManifest $content

$observabilityManifest = Join-Path $gitopsRoot "observability\stack.yaml"
$content = Read-Utf8Text $observabilityManifest
$content = $content -replace '(repoURL:\s*)https://github\.com/[^/\s]+/[^\s]+', "`${1}$GitOpsRepository"
$content = $content -replace 'https://api\.github\.com/repos/[^/\s]+/[^/\s]+/dispatches', $dispatchUrl
Write-Utf8Text $observabilityManifest $content

Write-Host "GitOps renderizado para a conta $accountId, região $awsRegion, bucket $veleroBucket e repositório $GitOpsRepository. Revise e faça commit."
