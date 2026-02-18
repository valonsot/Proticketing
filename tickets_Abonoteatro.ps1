[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ==========================================
# 1. VARIABLES GLOBALES
# ==========================================
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"

# ==========================================
# 2. FUNCIÓN CUENTA ATRÁS
# ==========================================
function Iniciar-CuentaAtras {
    param([int]$segundosTotales)
    for ($i = $segundosTotales; $i -gt 0; $i--) {
        $tiempo = New-TimeSpan -Seconds $i
        $reloj = "{0:D2}:{1:D2}" -f $tiempo.Minutes, $tiempo.Seconds
        Write-Host -NoNewline "`rEsperando para la próxima vuelta: $reloj " -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" + (" " * 40) + "`r" -NoNewline
}

# ==========================================
# 3. FUNCIÓN PRINCIPAL
# ==========================================
function MiFuncionPrincipal {
    $driver = $null
    try {
        # Instalar Selenium si no existe
        if (-not (Get-Module -ListAvailable Selenium)) {
            Write-Host "Instalando módulo Selenium..." -ForegroundColor Cyan
            Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
        }
        
        $modulePath = (Get-Module -ListAvailable Selenium).ModuleBase[0]
        $dllPath = Get-ChildItem -Path $modulePath -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
        Add-Type -Path $dllPath
        
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--user-agent=$uAgent")
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        
        Write-Host "--- Iniciando Navegador ---" -ForegroundColor Cyan
        $driver = [OpenQA.Selenium.Chrome.ChromeDriver]::new($options)
        
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 10 
        
        try {
            $botonAceptar = $driver.FindElement([OpenQA.Selenium.By]::XPath("//button[contains(., 'Aceptar Todas')]"))
            if ($botonAceptar) {
                $botonAceptar.Click()
                Start-Sleep -Seconds 5 
            }
        } catch { }
        
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = $uAgent
        foreach ($c in $driver.Manage().Cookies.AllCookies) {
            $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".oneboxtds.com")
            $session.Cookies.Add($newCookie)
        }
        
        $driver.Quit()
        $driver = $null

        # API Llamada
        $headers = @{ "Accept" = "application/json"; "Referer" = $urlPagina; "ob-channel-id" = "553" }
        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

        if ($response.data) {
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name
                    Cuando  = $e.date.start
                    Precio  = $e.minimumPrice
                    Recinto = $e.venues[0].name
                }
            }

            $csvPath = Join-Path $PSScriptRoot "eventos_abonoteatro_proticketing.csv"
            $eventosNuevos = @()
            if (Test-Path $csvPath) {
                $anteriores = (Import-Csv $csvPath -Delimiter ";").Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $anteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
            
            # Telegram
            if ($eventosNuevos.Count -gt 0) {
                $telegramToken = $env:TELEGRAM_TOKEN
                $archivoUsuarios = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                if (Test-Path $archivoUsuarios) {
                    $chatIds = Get-Content $archivoUsuarios | Where-Object { $_ -match '\d+' }
                    foreach ($nuevo in $eventosNuevos) {
                        foreach ($chatId in $chatIds) {
                            $texto = "⚠️ <b>NUEVO: $($nuevo.Nombre)</b>`n📍 $($nuevo.Recinto)"
                            $body = @{ chat_id = $chatId; text = $texto; parse_mode = "HTML" }
                            Invoke-RestMethod -Uri "https://api.telegram.org/bot$telegramToken/sendMessage" -Method Post -Body $body
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

# ==========================================
# 4. EJECUCIÓN DEL BUCLE (5 VECES)
# ==========================================
Write-Host "Iniciando ciclo de 5 comprobaciones..." -ForegroundColor Cyan

for ($intento = 1; $intento -le 5; $intento++) {
    Write-Host "`n>>> EJECUCIÓN $intento DE 5 <<<" -ForegroundColor Green
    
    MiFuncionPrincipal
    
    if ($intento -lt 5) {
        Iniciar-CuentaAtras -segundosTotales 120 
    }
}

Write-Host "`nProceso finalizado correctamente." -ForegroundColor Cyan
