[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN GLOBAL ---
$inicio = Get-Date
$fin = $inicio.AddHours(3)
$ultimaHora = "Nunca (Primera ejecución)"
$nombreCsv = "eventos_abonoteatro_proticketing.csv"
$csvPath = Join-Path $PSScriptRoot $nombreCsv

$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=70&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"

# 1. CARGAR SELENIUM (Solo una vez)
if (-not (Get-Module -ListAvailable Selenium)) {
    Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
}
$module = Get-Module -ListAvailable Selenium | Select-Object -First 1
$dllPath = Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
Add-Type -Path $dllPath

function Escape-Html {
    param([string]$texto)
    if ($null -eq $texto) { return "" }
    return $texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function MiFuncionSelenium {
    param($horaReferencia, $pathAlCsv) # AHORA SÍ RECIBE PARÁMETROS
    $driver = $null
    try {
        # 2. CONFIGURACIÓN CHROME
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        if (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") {
            $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        }
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--disable-blink-features=AutomationControlled")
        $options.AddExcludedArgument("enable-automation")
        $options.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36")

        # 3. INICIAR NAVEGADOR
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Iniciando navegador..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        
        # 4. CARGAR PÁGINA
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 20

        # 5. FETCH
        Write-Host "Paso 2: Ejecutando petición interna..." -ForegroundColor Cyan
        $jsScript = @"
            var done = arguments[arguments.length - 1];
            fetch('$urlApi', {
                headers: { "ob-channel-id": "553", "ob-client": "channels", "ob-language": "es-ES", "Accept": "application/json" }
            })
            .then(r => r.text()).then(d => done(d)).catch(e => done('ERROR: ' + e));
"@
        $driver.Manage().Timeouts().AsynchronousJavaScript = [TimeSpan]::FromSeconds(30)
        $jsonRaw = $driver.ExecuteAsyncScript($jsScript)

        if ($jsonRaw -like "ERROR:*") { throw $jsonRaw }

        $response = $jsonRaw | ConvertFrom-Json
        
        if ($response -and $response.data) {
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name.Trim()
                    Cuando  = $e.date.start
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # 7. GESTIÓN DEL CSV
            $eventosNuevos = @()
            if (Test-Path $pathAlCsv) {
                $csvAnterior = Import-Csv $pathAlCsv -Delimiter ";"
                $anteriores = $csvAnterior.Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            # GUARDADO CRÍTICO: Aquí es donde se actualiza el archivo
            $listaEventos | Export-Csv -Path $pathAlCsv -NoTypeInformation -Encoding UTF8 -Delimiter ";"
            Write-Host "CSV actualizado con $($listaEventos.Count) registros." -ForegroundColor Green
            
            # 8. TELEGRAM
            if ($eventosNuevos.Count -gt 0) {
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                $chatIds = Get-Content $userFile | ForEach-Object { if ($_ -match '(\d+)') { $matches[1] } } | Select-Object -Unique
                
                foreach ($ev in $eventosNuevos) {
                    $msg = "⚠️ <b>NUEVO EVENTO</b> ⚠️`n`n📌 <b>$(Escape-Html $ev.Nombre)</b>`n📍 $(Escape-Html $ev.Recinto)`n💰 $($ev.Precio)"
                    foreach ($id in $chatIds) {
                        $payload = @{ chat_id = $id; text = $msg; parse_mode = "HTML" } | ConvertTo-Json
                        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json" -Body $payload } catch {}
                    }
                }
            }
        }
    }
    catch { 
        Write-Host "⚠️ FALLO: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally { 
        if ($null -ne $driver) { $driver.Quit(); $driver.Dispose() }
    }
}

function Iniciar-CuentaAtras {
    param([int]$segundosTotales) # NOMBRE DE PARÁMETRO CORREGIDO
    for ($i = $segundosTotales; $i -gt 0; $i--) {
        $tiempo = New-TimeSpan -Seconds $i
        $reloj = "{0:D2}:{1:D2}" -f $tiempo.Minutes, $tiempo.Seconds
        Write-Host -NoNewline "`rPróxima revisión en: $reloj | Fin del script: $($fin.ToString('HH:mm:ss')) " -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" + (" " * 70) + "`r" -NoNewline
}

# --- BUCLE DE EJECUCIÓN ---
Write-Host "Script iniciado. Finalizará a las $($fin.ToString('HH:mm:ss'))" -ForegroundColor Magenta

while ((Get-Date) -lt $fin) {
    # Ejecución
    MiFuncionSelenium -horaReferencia $ultimaHora -pathAlCsv $csvPath
    
    $ultimaHora = Get-Date -Format "HH:mm:ss"

    # Espera Aleatoria
    $espera = Get-Random -Minimum 170 -Maximum 211
    
    if ((Get-Date).AddSeconds($espera) -lt $fin) {
        Iniciar-CuentaAtras -segundosTotales $espera # LLAMADA CORREGIDA
    } else {
        break
    }
}
Write-Host "`n[Script Terminado]" -ForegroundColor Gray
