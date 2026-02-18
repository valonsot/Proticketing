[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN ---
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"

function MiFuncionPrincipal {
    $driver = $null
    try {
        # 1. CARGAR SELENIUM (Dinámico para GitHub)
        if (-not (Get-Module -ListAvailable Selenium)) {
            Write-Host "Instalando Selenium en el servidor de GitHub..." -ForegroundColor Cyan
            Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
        }
        
        # Localizamos la DLL automáticamente en la carpeta del módulo instalado
        $module = Get-Module -ListAvailable Selenium | Select-Object -First 1
        $dllPath = Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
        Add-Type -Path $dllPath

        # 2. CONFIGURACIÓN CHROME (Headless obligatorio)
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        
        # --- ESTA ES LA LÍNEA CLAVE PARA GITHUB ---
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        # ------------------------------------------

        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--user-agent=$uAgent")

        Write-Host "Iniciando navegador con binario en: $($options.BinaryLocation)" -ForegroundColor Cyan
        $driver = [OpenQA.Selenium.Chrome.ChromeDriver]::new($options)
        # En GitHub no se pone ruta al driver, se detecta solo
        $driver = [OpenQA.Selenium.Chrome.ChromeDriver]::new($options)

        # 3. CAPTURA DE SESIÓN
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 12
        
        # Intentar cerrar cookies si aparecen
        try {
            $boton = $driver.FindElement([OpenQA.Selenium.By]::XPath("//button[contains(., 'Aceptar')]"))
            $boton.Click()
            Start-Sleep -Seconds 3
        } catch { }

        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = $uAgent
        foreach ($c in $driver.Manage().Cookies.AllCookies) {
            $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".oneboxtds.com")
            $session.Cookies.Add($newCookie)
        }

        # Cerramos navegador rápido para no consumir recursos
        $driver.Quit()
        $driver = $null

        # 4. LLAMADA A LA API
        Write-Host "Consultando API..." -ForegroundColor Cyan
        $headers = @{ "Accept" = "application/json"; "Referer" = $urlPagina; "ob-channel-id" = "553" }
        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

        if ($response.data) {
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name
                    Cuando  = $e.date.start
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # 5. GESTIÓN DE DATOS (Rutas relativas al repositorio)
            $csvPath = Join-Path $PSScriptRoot "eventos_anteriores.csv"
            $eventosNuevos = @()

            if (Test-Path $csvPath) {
                $anteriores = (Import-Csv $csvPath -Delimiter ";").Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            # Guardamos el estado actual
            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

            # 6. TELEGRAM
            if ($eventosNuevos.Count -gt 0) {
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                
                if (Test-Path $userFile) {
                    $ids = Get-Content $userFile | Where-Object { $_ -match '\d+' }
                    foreach ($ev in $eventosNuevos) {
                        foreach ($id in $ids) {
                            $msg = "<b>NUEVO: $($ev.Nombre)</b>`n📍 $($ev.Recinto)`n💰 $($ev.Precio)"
                            $body = @{ chat_id = $id; text = $msg; parse_mode = "HTML" }
                            Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body $body
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Error "Error: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $driver) { $driver.Quit() }
    }
}

# --- BUCLE DE 5 VECES ---
for ($i = 1; $i -le 5; $i++) {
    Write-Host "`n>>> EJECUCIÓN $i DE 5 <<<" -ForegroundColor Green
    MiFuncionPrincipal
    if ($i -lt 5) { 
        Write-Host "Esperando 2 min..." -ForegroundColor Gray
        Start-Sleep -Seconds 120 
    }
}
