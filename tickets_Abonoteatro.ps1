[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN ---
$intervaloMinutos = 3
$duracionTotalHoras = 3
$segundosEspera = $intervaloMinutos * 60

# Calculamos cuándo debe parar el script
$inicio = Get-Date
$fin = $inicio.AddHours($duracionTotalHoras)

$ultimaHora = "Nunca (Primera ejecución)"

# --- CONFIGURACIÓN ---
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"
$nombreCsv = "eventos_abonoteatro_proticketing.csv"

# 1. CARGAR SELENIUM
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
    $driver = $null
    try {
        # 2. CONFIGURACIÓN CHROME
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--disable-blink-features=AutomationControlled")
        $options.AddExcludedArgument("enable-automation")
        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        $options.AddArgument("--user-agent=$uAgent")

        # 3. INICIAR NAVEGADOR
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        Write-Host "Iniciando navegador..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        
        # 4. CARGAR PÁGINA PRINCIPAL
        Write-Host "Paso 1: Cargando portal de Abonoteatro..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 25 # Un poco más de tiempo para asegurar carga completa

        # 5. EJECUTAR FETCH CON HEADERS (Para evitar el BAD_REQUEST)
        Write-Host "Paso 2: Ejecutando petición interna con Metadatos..." -ForegroundColor Cyan
        $jsScript = @"
            var done = arguments[arguments.length - 1];
            fetch('$urlApi', {
                headers: {
                    "ob-channel-id": "553",
                    "ob-client": "channels",
                    "ob-language": "es-ES",
                    "Accept": "application/json, text/plain, */*"
                }
            })
            .then(response => response.text()) // Leemos como texto primero para depurar si falla
            .then(data => done(data))
            .catch(error => done('ERROR: ' + error));
"@
        $driver.Manage().Timeouts().AsynchronousJavaScript = [TimeSpan]::FromSeconds(30)
        $jsonRaw = $driver.ExecuteAsyncScript($jsScript)

        # 6. PROCESAR RESULTADOS
        if ($jsonRaw -like "ERROR:*") {
            throw "Error en Fetch de JavaScript: $jsonRaw"
        }

        $response = $jsonRaw | ConvertFrom-Json
        
        if ($response -and $response.data) {
            $totalEventos = $response.data.Count
            Write-Host "¡ÉXITO! Se han encontrado $totalEventos eventos." -ForegroundColor Green
            
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name.Trim()
                    Cuando  = $e.date.start
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # 7. GESTIÓN DEL CSV
            $csvPath = Join-Path $PSScriptRoot $nombreCsv
            $eventosNuevos = @()

            if (Test-Path $csvPath) {
                $csvAnterior = Import-Csv $csvPath -Delimiter ";"
                $anteriores = $csvAnterior.Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                Write-Host "Primera ejecución, creando base de datos CSV." -ForegroundColor Yellow
                $eventosNuevos = $listaEventos
            }

            # Actualizamos el CSV
            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
            Write-Host "Archivo CSV actualizado." -ForegroundColor Cyan
            
            # 8. TELEGRAM
            if ($eventosNuevos.Count -gt 0) {
                Write-Host "Enviando $($eventosNuevos.Count) novedades..." -ForegroundColor Magenta
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                $chatIds = Get-Content $userFile | ForEach-Object { if ($_ -match '(\d+)') { $matches[1] } } | Select-Object -Unique
                
                foreach ($ev in $eventosNuevos) {
                    $msg = "⚠️ <b>NUEVO EVENTO</b> ⚠️`n`n📌 <b>$(Escape-Html $ev.Nombre)</b>`n📍 $(Escape-Html $ev.Recinto)`n💰 $($ev.Precio)"
                    foreach ($id in $chatIds) {
                        $payload = @{ chat_id = $id; text = $msg; parse_mode = "HTML" } | ConvertTo-Json
                        try {
                            Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json" -Body $payload
                        } catch {}
                    }
                    Start-Sleep -Milliseconds 500
                }
            } else {
                Write-Host "No hay eventos nuevos." -ForegroundColor Green
            }
        } else {
            Write-Error "La API devolvió un error o está vacía: $jsonRaw"
        }
    }
    catch { 
        Write-Host "⚠️ FALLO EN ESTA EJECUCIÓN: $($_.Exception.Message)" -ForegroundColor Red
        if ($null -ne $driver) { 
            try { $driver.GetScreenshot().SaveAsFile("error_debug.png") } catch {}
        }
    }
    finally { 
        if ($null -ne $driver) { 
            $driver.Quit() 
            $driver.Dispose() # Añadimos Dispose para limpieza profunda
        }
        Write-Host "--- ESPERANDO SIGUIENTE CICLO ---" -ForegroundColor Gray
    }
}

function Iniciar-CuentaAtras {
    param([int]$segundos)
    for ($i = $segundos; $i -gt 0; $i--) {
        $tiempo = New-TimeSpan -Seconds $i
        $reloj = "{0:D2}:{1:D2}" -f $tiempo.Minutes, $tiempo.Seconds
        Write-Host -NoNewline "`rPróxima revisión en: $reloj (Finaliza a las $($fin.ToString("HH:mm:ss"))) " -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" + (" " * 60) + "`r" -NoNewline
}

# --- BUCLE DE EJECUCIÓN ---

Write-Host "Script iniciado. Se ejecutará cada $intervaloMinutos minutos hasta las $($fin.ToString("HH:mm:ss"))" -ForegroundColor Magenta

# Mientras la hora actual sea menor que la hora de fin...
while ((Get-Date) -lt $fin) {
    
    # 1. Ejecutamos la función
    MiFuncionSelenium -horaReferencia $ultimaHora
    
    # 2. Actualizamos la hora para la siguiente vuelta
    $ultimaHora = Get-Date -Format "HH:mm:ss"
    
    # 3. Verificamos si aún queda tiempo para otra espera
    if ((Get-Date).AddSeconds($segundosEspera) -lt $fin) {
        Iniciar-CuentaAtras -segundos $segundosEspera
    }
    else {
        Write-Host "`nSe ha alcanzado el límite de tiempo de 3 horas. Finalizando..." -ForegroundColor Magentax
        break
    }
}

Write-Host "`n[Script Terminado]" -ForegroundColor Gray
