[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DatabasePassword,
    [string]$DatabaseUsername = "solidary",
    [string]$NewRelicLicenseKey = "",
    [string]$PagerDutyIntegrationKey = "NOT_CONFIGURED",
    [string]$DiscordWebhookUrl = "https://example.invalid/discord-not-configured",
    [string]$GitHubPat = "NOT_CONFIGURED",
    [string]$TerraformDirectory = (Join-Path $PSScriptRoot "..\terraform")
)

$ErrorActionPreference = "Stop"
$rds = terraform "-chdir=$TerraformDirectory" output -json rds_endpoints | ConvertFrom-Json
$redis = (terraform "-chdir=$TerraformDirectory" output -raw redis_endpoint).Trim()
$queue = (terraform "-chdir=$TerraformDirectory" output -raw sqs_queue_url).Trim()
$encodedUser = [Uri]::EscapeDataString($DatabaseUsername)
$encodedPassword = [Uri]::EscapeDataString($DatabasePassword)

kubectl create namespace solidarytech --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

$appSecret = @{
    apiVersion = "v1"
    kind = "Secret"
    metadata = @{ name = "solidarytech-secrets"; namespace = "solidarytech" }
    type = "Opaque"
    stringData = @{
        NGO_DATABASE_URL = "postgresql://${encodedUser}:${encodedPassword}@$($rds.ngo):5432/ngo_db"
        DONATION_DATABASE_URL = "postgresql://${encodedUser}:${encodedPassword}@$($rds.donation):5432/donation_db"
        REDIS_ADDR = "${redis}:6379"
        AWS_SQS_URL = $queue
    }
}
$appSecret | ConvertTo-Json -Depth 5 | kubectl apply -f -

$newRelicSecret = @{
    apiVersion = "v1"; kind = "Secret"
    metadata = @{ name = "newrelic-license"; namespace = "observability" }
    type = "Opaque"; stringData = @{ "license-key" = $NewRelicLicenseKey }
}
$newRelicSecret | ConvertTo-Json -Depth 5 | kubectl apply -f -

$incidentSecret = @{
    apiVersion = "v1"; kind = "Secret"
    metadata = @{ name = "incident-integrations"; namespace = "observability" }
    type = "Opaque"
    stringData = @{
        PAGERDUTY_INTEGRATION_KEY = $PagerDutyIntegrationKey
        DISCORD_WEBHOOK_URL = $DiscordWebhookUrl
        GITHUB_PAT = $GitHubPat
    }
}
$incidentSecret | ConvertTo-Json -Depth 5 | kubectl apply -f -

Write-Host "Secrets aplicados sem gravar credenciais no repositório."
