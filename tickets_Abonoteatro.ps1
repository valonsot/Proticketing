[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN ---
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"
$nombreCsv = "eventos_abonoteatro_proticketing.csv"

function Escape-Html {
    param([string]$texto)
    if ($null -eq $texto) { return "" }
    return $texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function MiFuncionPrincipal {
    $driver = $null
    try {
        # 1. CARGAR SELENIUM
        if (-not (Get-Module -ListAvailable Selenium)) {
            Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
        }
        $module = Get-Module -ListAvailable Selenium | Select-Object -First 1
        Add-Type -Path (Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName)

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
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        
        # 4. PASO 1: CARGAR WEB PRINCIPAL
        Write-Host "Paso 1: Cargando página principal para obtener cookies..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 15

        # 5. PASO 2: NAVEGAR A LA API
        Write-Host "Paso 2: Accediendo a la API a través del navegador..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlApi)
        Start-Sleep -Seconds 8

        # --- EXTRACCIÓN ROBUSTA DE JSON ---
        # Intentamos obtener el texto del body, quitando posibles etiquetas HTML si el navegador las añade
        $rawText = $driver.FindElement([OpenQA.Selenium.By]::TagName("body")).Text
        
        # Si el texto parece HTML (tiene <html> o <body>), es que no hemos cargado el JSON sino una página de error
        if ($rawText -match "<html" -or $rawText -match "Forbidden" -or $rawText -match "Cloudflare") {
            Write-Warning "¡Bloqueo detectado! No se recibió JSON. Título: $($driver.Title)"
            $driver.GetScreenshot().SaveAsFile("error_debug.png")
            throw "El servidor denegó el acceso (403) o pidió verificación humana."
        }

        $response = $rawText | ConvertFrom-Json

        if ($response.data) {
            Write-Host "¡Acceso concedido! Procesando eventos..." -ForegroundColor Green
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name.Trim()
                    Cuando  = $e.date.start
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # COMPARACIÓN CSV
            $csvPath = Join-Path $PSScriptRoot $nombreCsv
            $eventosNuevos = @()
            if (Test-Path $csvPath) {
                $anteriores = (Import-Csv $csvPath -Delimiter ";").Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

            # TELEGRAM
            if ($eventosNuevos.Count -gt 0) {
                $token = $env:TELEGRAM_TOKEN
                $chatIds = Get-Content (Join-Path $PSScriptRoot "usuarios_telegram.txt") | ForEach-Object { if ($_ -match '(\d+)') { $matches[1] } } | Select-Object -Unique
                
                foreach ($ev in $eventosNuevos) {
                    $msg = "⚠️ <b>NUEVO EVENTO</b> ⚠️`n`n📌 <b>$(Escape-Html $ev.Nombre)</b>`n📍 $(Escape-Html $ev.Recinto)`n💰 $($ev.Precio)"
                    foreach ($id in $chatIds) {
                        $payload = @{ chat_id = $id; text = $msg; parse_mode = "HTML" } | ConvertTo-Json
                        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json" -Body $payload } catch {}
                    }
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }
    catch { 
        Write-Error "Fallo: $($_.Exception.Message)" 
        if ($null -ne $driver) {
            Write-Host "Guardando captura de pantalla de emergencia..." -ForegroundColor Magenta
            $driver.GetScreenshot().SaveAsFile("error_debug.png")
        }
    }
    finally { 
        if ($null -ne $driver) { $driver.Quit() } 
    }
}

MiFuncionPrincipal
