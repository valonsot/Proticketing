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
        Write-Host "Cargando página principal..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 15

        # 5. PASO 2: NAVEGAR A LA API DIRECTAMENTE
        Write-Host "Consultando API a través del navegador..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlApi)
        Start-Sleep -Seconds 8

        # Extraer el JSON del cuerpo de la página (más robusto que buscar <pre>)
        $jsonRaw = $driver.FindElement([OpenQA.Selenium.By]::TagName("body")).Text
        
        if ($jsonRaw -match "Forbidden" -or $jsonRaw -match "Cloudflare") {
            $driver.GetScreenshot().SaveAsFile("error_debug.png")
            throw "Bloqueo detectado por el servidor."
        }

        $response = $jsonRaw | ConvertFrom-Json

        if ($response.data) {
            Write-Host "¡Datos recibidos! Procesando..." -ForegroundColor Green
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name.Trim()
                    Cuando  = $e.date.start
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # 6. GESTIÓN DEL ARCHIVO CSV EN EL REPOSITORIO
            $csvPath = Join-Path $PSScriptRoot $nombreCsv
            $eventosNuevos = @()

            if (Test-Path $csvPath) {
                Write-Host "Comparando con el archivo del repositorio..." -ForegroundColor Gray
                # Leemos el archivo que ya tienes (usando ; como separador)
                $anteriores = (Import-Csv $csvPath -Delimiter ";").Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            # SOBREESCRIBIMOS EL ARCHIVO con toda la información nueva
            # Esto es lo que luego el archivo .yml subirá a GitHub
            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
            Write-Host "Archivo CSV actualizado localmente." -ForegroundColor Green

            # 7. TELEGRAM (Solo si hay novedades)
            if ($eventosNuevos.Count -gt 0) {
                Write-Host "Enviando $($eventosNuevos.Count) novedades a Telegram..." -ForegroundColor Magenta
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                $chatIds = Get-Content $userFile | ForEach-Object { if ($_ -match '(\d+)') { $matches[1] } } | Select-Object -Unique
                
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
        if ($null -ne $driver) { $driver.GetScreenshot().SaveAsFile("error_debug.png") }
    }
    finally { 
        if ($null -ne $driver) { $driver.Quit() } 
    }
}

MiFuncionPrincipal
