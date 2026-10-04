<#
.SYNOPSIS
    Gera carga HTTP contra a SolidaryTech para evidenciar o Horizontal Pod Autoscaler.

.DESCRIPTION
    Dispara requisições concorrentes contra ngo-service, donation-service ou volunteer-service
    e imprime vazão, distribuição de status e latência p50/p95/p99. Com -WatchHpa, acompanha
    `kubectl get hpa` durante a execução para registrar o escalonamento no vídeo da entrega.

    Os payloads seguem os contratos reais das APIs: e-mails de ONG são únicos por requisição
    para não colidir no índice (HTTP 409) e o POST /donations envia apenas os campos aceitos,
    porque o handler Go usa DisallowUnknownFields.

.PARAMETER BaseUrl
    Raiz das APIs. No cluster, a URL do Load Balancer do Ingress (serve os três caminhos).
    Localmente, o host:porta de um único serviço (ex.: http://localhost:8082).

.PARAMETER Service
    Serviço alvo: donation, ngo, volunteer ou all. O valor all exige o Ingress, pois alterna
    entre os três caminhos na mesma origem.

.PARAMETER ReadPercent
    Percentual de GETs na mistura. Em donation, os GETs exercitam o cache Redis.

.EXAMPLE
    .\scripts\gerar-carga.ps1 -BaseUrl http://a1b2c3.elb.amazonaws.com -Service donation -WatchHpa

.EXAMPLE
    .\scripts\gerar-carga.ps1 -BaseUrl http://localhost:8082 -Service donation -DurationSeconds 60 -Concurrency 8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [ValidateSet("donation", "ngo", "volunteer", "all")][string]$Service = "donation",
    [ValidateRange(10, 3600)][int]$DurationSeconds = 120,
    [ValidateRange(1, 500)][int]$Concurrency = 20,
    [ValidateRange(0, 100)][int]$ReadPercent = 30,
    [string]$Namespace = "solidarytech",
    [switch]$WatchHpa
)

$ErrorActionPreference = "Stop"

if ($BaseUrl -notmatch '^https?://') { throw "BaseUrl deve começar com http:// ou https://." }
$BaseUrl = $BaseUrl.TrimEnd("/")

$kubectl = $null
if ($WatchHpa) {
    $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
    if (-not $kubectl) { throw "-WatchHpa exige o kubectl no PATH." }
}

function Show-Hpa([string]$Label) {
    Write-Host ""
    Write-Host "--- HPA ($Label) ---" -ForegroundColor Cyan
    & kubectl get hpa -n $Namespace
    & kubectl get deploy -n $Namespace -o "custom-columns=DEPLOY:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas"
}

$worker = {
    param($BaseUrl, $Service, $Deadline, $ReadPercent)

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 1000
    [System.Net.ServicePointManager]::Expect100Continue = $false
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    $random = New-Object System.Random ([int]((Get-Date).Ticks % [int]::MaxValue))
    $paths = @("donation", "ngo", "volunteer")
    $statuses = @{}
    $latencies = New-Object System.Collections.Generic.List[double]
    $failures = 0
    $count = 0

    while ((Get-Date) -lt $Deadline) {
        $target = $Service
        if ($Service -eq "all") { $target = $paths[$random.Next(0, 3)] }
        $isRead = ($random.Next(0, 100) -lt $ReadPercent)
        $ngoId = $random.Next(1, 6)

        $method = "POST"
        $url = $null
        $body = $null

        switch ($target) {
            "donation" {
                if ($isRead) { $method = "GET"; $url = "$BaseUrl/donations" }
                else {
                    $url = "$BaseUrl/donations"
                    $amount = [math]::Round($random.NextDouble() * 500 + 10, 2)
                    $body = @{ ngo_id = $ngoId; amount = $amount; donor_name = "Doador $($random.Next(1000, 9999))" }
                }
            }
            "ngo" {
                if ($isRead) { $method = "GET"; $url = "$BaseUrl/ngos" }
                else {
                    $url = "$BaseUrl/ngos"
                    $unique = [guid]::NewGuid().ToString("N")
                    $body = @{ name = "ONG $($unique.Substring(0, 8))"; email = "$unique@carga.solidarytech.test"; cause = "Educacao"; city = "Sao Paulo" }
                }
            }
            "volunteer" {
                if ($isRead) { $method = "GET"; $url = "$BaseUrl/volunteers/$ngoId" }
                else {
                    $url = "$BaseUrl/volunteers"
                    $unique = [guid]::NewGuid().ToString("N")
                    $body = @{ name = "Voluntario $($unique.Substring(0, 8))"; email = "$unique@carga.solidarytech.test"; ngo_id = $ngoId }
                }
            }
        }

        $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::$method), $url
        if ($body) {
            $json = $body | ConvertTo-Json -Compress
            $request.Content = New-Object System.Net.Http.StringContent $json, ([System.Text.Encoding]::UTF8), "application/json"
        }

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $clock.Stop()
            $code = [int]$response.StatusCode
            $response.Dispose()
            $latencies.Add($clock.Elapsed.TotalMilliseconds)
            if (-not $statuses.ContainsKey($code)) { $statuses[$code] = 0 }
            $statuses[$code]++
        }
        catch {
            $clock.Stop()
            $failures++
        }
        finally { $request.Dispose() }
        $count++
    }

    $client.Dispose()
    [pscustomobject]@{ Count = $count; Failures = $failures; Statuses = $statuses; Latencies = $latencies }
}

function Get-Percentile($Sorted, [double]$Percentile) {
    if ($Sorted.Count -eq 0) { return 0 }
    $index = [int][math]::Ceiling(($Percentile / 100.0) * $Sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Sorted.Count) { $index = $Sorted.Count - 1 }
    return $Sorted[$index]
}

Write-Host "Alvo .............. $Service em $BaseUrl"
Write-Host "Duração ........... $DurationSeconds s"
Write-Host "Concorrência ...... $Concurrency"
Write-Host "Mistura ........... $ReadPercent% GET / $(100 - $ReadPercent)% POST"

if ($WatchHpa) { Show-Hpa "antes" }

$deadline = (Get-Date).AddSeconds($DurationSeconds)
$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()
$running = @()

for ($i = 0; $i -lt $Concurrency; $i++) {
    $shell = [powershell]::Create()
    $shell.RunspacePool = $pool
    $null = $shell.AddScript($worker).AddArgument($BaseUrl).AddArgument($Service).AddArgument($deadline).AddArgument($ReadPercent)
    $running += [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
}

Write-Host ""
Write-Host "Gerando carga..." -ForegroundColor Yellow
$nextHpa = (Get-Date).AddSeconds(30)
while ($running.Handle.IsCompleted -contains $false) {
    Start-Sleep -Seconds 5
    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
    if ($remaining -lt 0) { $remaining = 0 }
    Write-Host "  restam ${remaining}s"
    if ($WatchHpa -and (Get-Date) -ge $nextHpa -and $remaining -gt 0) {
        Show-Hpa "durante"
        $nextHpa = (Get-Date).AddSeconds(30)
    }
}

$total = 0
$failures = 0
$statuses = @{}
$latencies = New-Object System.Collections.Generic.List[double]

foreach ($item in $running) {
    $result = $item.Shell.EndInvoke($item.Handle)
    $item.Shell.Dispose()
    foreach ($slice in $result) {
        $total += $slice.Count
        $failures += $slice.Failures
        $latencies.AddRange($slice.Latencies)
        foreach ($code in $slice.Statuses.Keys) {
            if (-not $statuses.ContainsKey($code)) { $statuses[$code] = 0 }
            $statuses[$code] += $slice.Statuses[$code]
        }
    }
}
$pool.Close()
$pool.Dispose()

$sorted = $latencies | Sort-Object
$rps = 0
if ($DurationSeconds -gt 0) { $rps = [math]::Round($total / $DurationSeconds, 1) }

Write-Host ""
Write-Host "=== Resultado ===" -ForegroundColor Green
Write-Host "Requisições ....... $total"
Write-Host "Vazão ............. $rps req/s"
Write-Host "Falhas de rede .... $failures"
if ($sorted.Count -gt 0) {
    Write-Host "Latência p50 ...... $([math]::Round((Get-Percentile $sorted 50), 1)) ms"
    Write-Host "Latência p95 ...... $([math]::Round((Get-Percentile $sorted 95), 1)) ms"
    Write-Host "Latência p99 ...... $([math]::Round((Get-Percentile $sorted 99), 1)) ms"
}
Write-Host "Status HTTP:"
foreach ($code in ($statuses.Keys | Sort-Object)) {
    $share = [math]::Round(100.0 * $statuses[$code] / [math]::Max($total, 1), 1)
    Write-Host ("  {0} .............. {1} ({2}%)" -f $code, $statuses[$code], $share)
}

if ($WatchHpa) {
    Show-Hpa "depois"
    Write-Host ""
    Write-Host "O scaleDown tem janela de estabilização de 300s: as réplicas só recuam alguns minutos após o fim da carga." -ForegroundColor DarkGray
}
