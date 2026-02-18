[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN ---
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"

# --- FUNCIÓN CUENTA ATRÁS ---
function Iniciar-CuentaAtras {
    param([int]$segundosTotales)
    for ($i = $segundosTotales; $i -gt 0; $i--) {
        $reloj = "{0:D2}:{1:D2}" -f ([timespan]::FromSeconds($i).Minutes), ([timespan]::FromSeconds($i).Seconds)
        Write-Host -NoNewline "`rEsperando para la próxima vuelta: $reloj " -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" + (" " * 40) + "`r" -NoNewline
}

# --- FUNCIÓN PARA ESCAPAR HTML (Evita el error 400 de Telegram) ---
function Escape-Html {
    param([string]$texto)
    if ($null -eq $texto) { return "" }
    return $texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

# --- FUNCIÓN PRINCIPAL ---
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

        # 2. CONFIGURACIÓN CHROME
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--user-agent=$uAgent")

        # 3. INICIAR NAVEGADOR
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        Write-Host "Iniciando navegador..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)

        # 4. CAPTURA DE SESIÓN
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 12
        
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

        $driver.Quit()
        $driver = $null

        # 5. LLAMADA A LA API
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

            # 6. GESTIÓN DE DATOS
            $csvPath = Join-Path $PSScriptRoot "eventos_anteriores.csv"
            $eventosNuevos = @()

            if (Test-Path $csvPath) {
                $anteriores = (Import-Csv $csvPath -Delimiter ";").Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

            # 7. TELEGRAM (Corregido para evitar Error 400)
            if ($eventosNuevos.Count -gt 0) {
                Write-Host "¡Encontrados $($eventosNuevos.Count) eventos nuevos!" -ForegroundColor Magenta
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                
                if (Test-Path $userFile) {
                    $ids = Get-Content $userFile | Where-Object { $_ -match '\d+' } | ForEach-Object { $_.Trim() }
                    
                    foreach ($ev in $eventosNuevos) {
                        # Escapamos caracteres especiales para que Telegram no de error 400
                        $nombreEscapado = Escape-Html $ev.Nombre
                        $recintoEscapado = Escape-Html $ev.Recinto

                        foreach ($id in $ids) {
                            $msg = "⚠️ <b>NUEVO EVENTO</b> ⚠️`n`n📌 <b>$nombreEscapado</b>`n📍 $recintoEscapado`n💰 $($ev.Precio)"
                            
                            $payload = @{
                                chat_id    = $id
                                text       = $msg
                                parse_mode = "HTML"
                            } | ConvertTo-Json

                            try {
                                Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" `
                                                  -Method Post `
                                                  -ContentType "application/json; charset=utf-8" `
                                                  -Body $payload
                                Write-Host "Notificación enviada a $id" -ForegroundColor Gray
                            } catch {
                                Write-Warning "Error enviando a $id : $($_.Exception.Message)"
                            }
                        }
                        # Pequeña pausa para no saturar a Telegram (antispam)
                        Start-Sleep -Milliseconds 500
                    }
                }
            } else {
                Write-Host "Sin novedades." -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Error "Error en la ejecución: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $driver) { $driver.Quit() }
    }
}

# --- BUCLE DE 5 VECES ---
for ($i = 1; $i -le 5; $i++) {
    Write-Host "`n>>> EJECUCIÓN $i DE 5 <<<" -ForegroundColor Green
    MiFuncionPrincipal
    if ($i -lt 5) { Iniciar-CuentaAtras -segundosTotales 120 }
}
