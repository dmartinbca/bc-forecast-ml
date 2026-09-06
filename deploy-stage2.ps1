param(
    [Parameter(Mandatory)][string]$Suscripcion,
    [string]$Grupo      = "rg-bc-forecast",
    [string]$Region     = "westeurope",
    [string]$Imagen     = "ghcr.io/dmartinbca/bc-forecast:1.0",
    [string]$PlanNombre = "asp-bc-forecast",
    [string]$AppNombre,
    [string]$Sku        = "B1",
    [string]$ApiKey
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Nombre App globalmente único determinístico por suscripción
$md5  = [System.Security.Cryptography.MD5]::Create()
$hash = [System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Suscripcion))).Replace('-','').Substring(0,8).ToLower()
if ([string]::IsNullOrWhiteSpace($AppNombre)) { $AppNombre = "bc-forecast-$hash" }

function Invoke-AzRetry {
    param(
        [Parameter(Mandatory)][string[]]$AzArgs,
        [int]$MaxAttempts     = 8,
        [int]$InitialDelaySec = 2,
        [int]$MaxDelaySec     = 30,
        [switch]$ReturnOutput
    )

    $attempt = 0
    while ($true) {
        $attempt++
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & az @AzArgs 2>&1
        $code   = $LASTEXITCODE
        $ErrorActionPreference = $oldEAP

        if ($code -eq 0) {
            if ($ReturnOutput) { return ($output | Out-String).Trim() }
            return
        }

        $errStr    = ($output | Out-String)
        $retriable = $errStr -match "ConnectionResetError|Connection aborted|ConnectionError|10054|TimeoutError|HTTPSConnectionPool|temporarily unavailable|\b(429|500|502|503|504)\b"

        if ($attempt -ge $MaxAttempts -or -not $retriable) {
            Write-Host "    Intento $attempt/$MaxAttempts - fallo NO recuperable" -ForegroundColor Red
            Write-Host $errStr -ForegroundColor Red
            throw "az fallo: $($AzArgs -join ' ')"
        }

        $delay = [int][Math]::Min($InitialDelaySec * [Math]::Pow(2, $attempt - 1), $MaxDelaySec)
        Write-Host "    Intento $attempt/$MaxAttempts fallo (network). Reintento en $delay s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $delay
    }
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $ApiKey = [Convert]::ToBase64String($bytes)
}

Write-Host "==> Suscripcion: $Suscripcion"
Invoke-AzRetry -AzArgs @('account','set','--subscription',$Suscripcion)

Write-Host "==> App Service Plan: $PlanNombre ($Sku Linux)"
Invoke-AzRetry -AzArgs @('appservice','plan','create','--name',$PlanNombre,'--resource-group',$Grupo,'--is-linux','--sku',$Sku,'--output','none')

Write-Host "==> Web App: $AppNombre (imagen $Imagen)"
Invoke-AzRetry -AzArgs @(
    'webapp','create',
    '--resource-group',$Grupo,
    '--plan',$PlanNombre,
    '--name',$AppNombre,
    '--deployment-container-image-name',$Imagen,
    '--output','none'
)

Write-Host "==> Container settings (ghcr.io publico, sin auth) + puerto 8080..."
# Sin credenciales: ghcr.io es publico
Invoke-AzRetry -AzArgs @(
    'webapp','config','container','set',
    '--name',$AppNombre,
    '--resource-group',$Grupo,
    '--container-image-name',$Imagen,
    '--container-registry-url','https://ghcr.io',
    '--output','none'
)

Write-Host "==> App settings (API_KEY + WEBSITES_PORT=8080)..."
Invoke-AzRetry -AzArgs @(
    'webapp','config','appsettings','set',
    '--resource-group',$Grupo,
    '--name',$AppNombre,
    '--settings',"API_KEY=$ApiKey","WEBSITES_PORT=8080",
    '--output','none'
)

Write-Host "==> Reiniciando Web App..."
Invoke-AzRetry -AzArgs @('webapp','restart','--resource-group',$Grupo,'--name',$AppNombre)

$DefaultHost = Invoke-AzRetry -ReturnOutput -AzArgs @('webapp','show','-g',$Grupo,'-n',$AppNombre,'--query','defaultHostName','-o','tsv')
$UrlApi = "https://$DefaultHost/execute"

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  DESPLIEGUE COMPLETADO"                          -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "URI de API  : $UrlApi"                            -ForegroundColor Cyan
Write-Host "Clave de API: $ApiKey"                            -ForegroundColor Cyan
Write-Host ""
Write-Host "Web App         : $AppNombre"
Write-Host "Default hostname: $DefaultHost"
Write-Host ""
Write-Host "Pega URI y Clave en Business Central:"
Write-Host "  Configuracion de prevision de ventas e inventario"
Write-Host ""
Write-Host "El primer arranque del container R tarda 1-2 min (pull desde ghcr.io)."
Write-Host "Smoke test (despues de 2 min):"
Write-Host "  Invoke-WebRequest -Uri https://$DefaultHost/ -Method GET"
Write-Host ""
