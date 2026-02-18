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

        # 2. CONFIGURACIÓN CHROME "HUMANIZADO"
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        
        # Argumentos de evasión
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        
        # Engañar a Cloudflare: Ocultar que es un bot
        $options.AddArgument("--disable-blink-features=AutomationControlled")
        $options.AddExcludedArgument("enable-automation")
        $options.AddAdditionalOption("useAutomationExtension", $false)
        
        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        $options.AddArgument("--user-agent=$uAgent")

        # 3. INICIAR NAVEGADOR
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        
        # Ejecutar script para borrar rastros de Selenium
        $driver.ExecuteScript("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")

        Write-Host "Navegando a Proticketing..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        
        # Espera aleatoria para parecer humano
        Start-Sleep -Seconds (Get-Random -Minimum 15 -Maximum 25)

        # DEBUG: ¿Qué está viendo el bot?
        Write-Host "Título de la página: $($driver.Title)" -ForegroundColor Yellow
        if ($driver.Title -match "Cloudflare" -or $driver.Title -match "Just a moment") {
            Write-Error "BLOQUEO DETECTADO: Cloudflare está desafiando la conexión."
            $driver.GetScreenshot().SaveAsFile((Join-Path $PSScriptRoot "bloqueo_cloudflare.png"))
            return
        }

        # 4. CAPTURA DE SESIÓN
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = $uAgent
        foreach ($c in $driver.Manage().Cookies.AllCookies) {
            $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".oneboxtds.com")
            $session.Cookies.Add($newCookie)
        }
        $driver.Quit()
        $driver = $null

        # 5. LLAMADA A LA API (Con Headers más realistas)
        Write-Host "Consultando API con sesión capturada..." -ForegroundColor Cyan
        $headers = @{ 
            "Accept"          = "application/json, text/plain, */*"
            "Accept-Language" = "es-ES,es;q=0.9"
            "Referer"         = $urlPagina
            "ob-channel-id"   = "553"
            "ob-client"       = "channels"
            "Origin"          = "https://tickets.oneboxtds.com"
            "Sec-Fetch-Dest"  = "empty"
            "Sec-Fetch-Mode"  = "cors"
            "Sec-Fetch-Site"  = "same-origin"
        }

        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

        if ($response.data) {
            Write-Host "API respondió correctamente." -ForegroundColor Green
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
        if ($driver) { $driver.GetScreenshot().SaveAsFile((Join-Path $PSScriptRoot "error_debug.png")) }
    }
    finally { if ($null -ne $driver) { $driver.Quit() } }
}

# Ejecutar una vez para probar (en GitHub Actions no abusar de bucles si hay bloqueos)
MiFuncionPrincipal
