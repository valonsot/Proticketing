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

        # 2. CONFIGURACIÓN CHROME "HUMANO"
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
        
        # 4. NAVEGAR A LA WEB PRINCIPAL (Para cookies)
        Write-Host "Cargando página principal..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds (Get-Random -Minimum 12 -Maximum 18)

        # 5. PEDIR LA API DESDE EL NAVEGADOR (Evasión total del 403)
        Write-Host "Consultando API a través del navegador..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlApi)
        Start-Sleep -Seconds 5

        # Extraer el contenido del JSON que muestra el navegador
        $jsonRaw = $driver.FindElement([OpenQA.Selenium.By]::TagName("pre")).Text
        
        if (-not $jsonRaw) {
            # Si no hay etiqueta <pre>, intentamos capturar todo el body (algunas versiones de Chrome lo muestran así)
            $jsonRaw = $driver.FindElement([OpenQA.Selenium.By]::TagName("body")).Text
        }

        $response = $jsonRaw | ConvertFrom-Json

        if ($response.data) {
            Write-Host "¡Acceso concedido! Procesando $($response.data.Count) eventos..." -ForegroundColor Green
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
        } else {
            throw "La API no devolvió datos. Posible bloqueo."
        }
    }
    catch { 
        Write-Error "Fallo: $($_.Exception.Message)" 
        if ($driver) {
            $pathPng = Join-Path $env:GITHUB_WORKSPACE "error_debug.png"
            Write-Host "Guardando captura de seguridad en: $pathPng" -ForegroundColor Magenta
            $driver.GetScreenshot().SaveAsFile($pathPng)
        }
    }
    finally { 
        if ($null -ne $driver) { $driver.Quit() } 
    }
}

MiFuncionPrincipal
