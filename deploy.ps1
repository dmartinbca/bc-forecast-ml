param(
    [Parameter(Mandatory)][string]$Suscripcion,
    [string]$Grupo      = "rg-bc-forecast",
    [string]$Region     = "westeurope",
    [string]$AcrNombre,
    [string]$Imagen     = "bc-forecast:1.0",
    [string]$AppNombre,
    [string]$PlanNombre = "asp-bc-forecast",
    [string]$Sku        = "B1",
    [string]$ApiKey
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

# Hash determinístico por suscripción → nombres idempotentes y globalmente únicos
$md5  = [System.Security.Cryptography.MD5]::Create()
$hash = [System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Suscripcion))).Replace('-','').Substring(0,8).ToLower()
if ([string]::IsNullOrWhiteSpace($AcrNombre)) { $AcrNombre = "acrbcforecast$hash" }
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
            Write-Host "    Intento $attempt/$MaxAttempts - fallo NO recuperable o agotados reintentos" -ForegroundColor Red
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

Write-Host "==> Resource Group: $Grupo ($Region)"
Invoke-AzRetry -AzArgs @('group','create','--name',$Grupo,'--location',$Region,'--output','none')

Write-Host "==> ACR: $AcrNombre"
Invoke-AzRetry -AzArgs @('acr','create','--resource-group',$Grupo,'--name',$AcrNombre,'--sku','Basic','--admin-enabled','true','--output','none')

Write-Host "==> Build remoto de la imagen (~8-12 min, 3 reintentos max)..."
$buildOk = $false
for ($i = 1; $i -le 3; $i++) {
    Write-Host "    Build intento $i/3..."
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & az acr build --registry $AcrNombre --image $Imagen . 2>&1 | ForEach-Object { Write-Host "      $_" }
    $buildCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP
    if ($buildCode -eq 0) { $buildOk = $true; break }
    Write-Host "    Build fallo (exit $buildCode), reintentando en 30 s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
}
if (-not $buildOk) { throw "ACR build fallo tras 3 intentos" }

Write-Host "==> Credenciales ACR..."
$AcrServer = "$AcrNombre.azurecr.io"
$AcrUser   = Invoke-AzRetry -ReturnOutput -AzArgs @('acr','credential','show','-n',$AcrNombre,'--query','username','-o','tsv')
$AcrPass   = Invoke-AzRetry -ReturnOutput -AzArgs @('acr','credential','show','-n',$AcrNombre,'--query','passwords[0].value','-o','tsv')

Write-Host "==> App Service Plan: $PlanNombre ($Sku Linux)"
Invoke-AzRetry -AzArgs @('appservice','plan','create','--name',$PlanNombre,'--resource-group',$Grupo,'--is-linux','--sku',$Sku,'--output','none')

Write-Host "==> Web App: $AppNombre"
Invoke-AzRetry -AzArgs @(
    'webapp','create',
    '--resource-group',$Grupo,
    '--plan',$PlanNombre,
    '--name',$AppNombre,
    '--deployment-container-image-name',"$AcrServer/$Imagen",
    '--output','none'
)

Write-Host "==> Configurando container settings (ACR + puerto 8080)..."
Invoke-AzRetry -AzArgs @(
    'webapp','config','container','set',
    '--name',$AppNombre,
    '--resource-group',$Grupo,
    '--container-image-name',"$AcrServer/$Imagen",
    '--container-registry-url',"https://$AcrServer",
    '--container-registry-user',$AcrUser,
    '--container-registry-password',$AcrPass,
    '--output','none'
)

Invoke-AzRetry -AzArgs @(
    'webapp','config','appsettings','set',
    '--resource-group',$Grupo,
    '--name',$AppNombre,
    '--settings',"API_KEY=$ApiKey","WEBSITES_PORT=8080",
    '--output','none'
)

Write-Host "==> Reiniciando Web App para que tome la nueva imagen..."
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
Write-Host "Pega esos valores en Business Central:"
Write-Host "  Configuracion de prevision de ventas e inventario"
Write-Host ""
Write-Host "Smoke test (espera 2-3 min al primer arranque del container):"
Write-Host "  Invoke-WebRequest -Uri https://$DefaultHost/ -Method GET"
Write-Host ""
Write-Host "Logs del container:"
Write-Host "  az webapp log tail -g $Grupo -n $AppNombre"
Write-Host ""
