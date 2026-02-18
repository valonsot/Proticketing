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
            Write-Host "Instalando Selenium..." -ForegroundColor Cyan
            Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
        }
        $module = Get-Module -ListAvailable Selenium | Select-Object -First 1
        $dllPath = Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
        Add-Type -Path $dllPath

        # 2. CONFIGURACIÓN CHROME (MODO EVASIÓN)
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        
        # Argumentos estándar
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        
        # --- TÉCNICAS ANTI-DETECCIÓN ---
        # 1. Ocultar que es un bot a nivel de navegador
        $options.AddArgument("--disable-blink-features=AutomationControlled")
        
        # 2. Eliminar la bandera "Chrome is being controlled by automated software"
        $options.AddExcludedArgument("enable-automation")
        
        # 3. Desactivar extensiones de automatización (Usando propiedad, no método)
        try { $options.UseAutomationExtension = $false } catch { }
        
        # 4. User Agent moderno y real
        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        $options.AddArgument("--user-agent=$uAgent")

        # 3. INICIAR NAVEGADOR
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        Write-Host "Iniciando navegador humanizado..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        
        # 4. TRUCO FINAL: Borrar la huella de Selenium en ejecución
        $driver.ExecuteScript("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")

        Write-Host "Navegando a Proticketing..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($urlPagina)
        
        # Espera larga y aleatoria (Cloudflare odia la velocidad constante)
        $espera = Get-Random -Minimum 15 -Maximum 25
        Write-Host "Esperando $espera segundos para simular lectura humana..." -ForegroundColor Yellow
        Start-Sleep -Seconds $espera

        # Verificación de bloqueo
        Write-Host "Título de la página: $($driver.Title)" -ForegroundColor Gray
        if ($driver.Title -match "Cloudflare" -or $driver.Title -match "Just a moment") {
            Write-Warning "AVISO: Cloudflare ha presentado un desafío. La IP de GitHub podría estar marcada."
            $driver.GetScreenshot().SaveAsFile((Join-Path $PSScriptRoot "bloqueo_detectado.png"))
        }

        # 5. CAPTURA DE SESIÓN
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = $uAgent
        foreach ($c in $driver.Manage().Cookies.AllCookies) {
            $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".oneboxtds.com")
            $session.Cookies.Add($newCookie)
        }
        $driver.Quit()
        $driver = $null

        # 6. LLAMADA A LA API (Con Headers fingiendo ser el navegador)
        Write-Host "Consultando API con identidad suplantada..." -ForegroundColor Cyan
        $headers = @{ 
            "Accept"          = "application/json, text/plain, */*"
            "Referer"         = $urlPagina
            "ob-channel-id"   = "553"
            "ob-client"       = "channels"
            "sec-ch-ua-mobile" = "?0"
            "sec-ch-ua-platform" = '"Windows"'
        }

        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

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
        if ($driver) { $driver.GetScreenshot().SaveAsFile((Join-Path $PSScriptRoot "error_debug.png")) }
    }
    finally { if ($null -ne $driver) { $driver.Quit() } }
}

# Ejecutar
MiFuncionPrincipal
