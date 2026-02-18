[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- CONFIGURACIÓN ---
$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"
$nombreCsv = "eventos_abonoteatro_proticketing.csv"

# --- FUNCIÓN PARA ESCAPAR HTML (Telegram) ---
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
            Install-Module -Name Selenium -Force -Scope CurrentUser -AllowClobber
        }
        $module = Get-Module -ListAvailable Selenium | Select-Object -First 1
        $dllPath = Get-ChildItem -Path $module.ModuleBase -Filter "WebDriver.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
        Add-Type -Path $dllPath

        # 2. CONFIGURACIÓN CHROME
        $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
        $options.BinaryLocation = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        $options.AddArgument("--headless=new") 
        $options.AddArgument("--no-sandbox")
        $options.AddArgument("--disable-dev-shm-usage")
        $options.AddArgument("--window-size=1920,1080")
        $options.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

        # 3. INICIAR NAVEGADOR Y SESIÓN
        $rutaDriver = if ($env:CHROMEWEBDRIVER) { $env:CHROMEWEBDRIVER } else { $PSScriptRoot }
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($rutaDriver, $options)
        $driver.Navigate().GoToUrl($urlPagina)
        Start-Sleep -Seconds 12
        
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        foreach ($c in $driver.Manage().Cookies.AllCookies) {
            $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".oneboxtds.com")
            $session.Cookies.Add($newCookie)
        }
        $driver.Quit()

        # 4. LLAMADA A LA API
        Write-Host "Consultando API de eventos..." -ForegroundColor Cyan
        $headers = @{ "Accept" = "application/json"; "Referer" = $urlPagina; "ob-channel-id" = "553" }
        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

        if ($response.data) {
            $listaEventos = foreach ($e in $response.data) {
                [PSCustomObject]@{
                    Nombre  = $e.name.Trim()
                    Cuando  = "Desde: $($e.date.start) Hasta: $($e.date.end)"
                    Precio  = if ($e.minimumPrice) { "$($e.minimumPrice)€" } else { "Consultar" }
                    Recinto = $e.venues[0].name
                }
            }

            # 5. COMPARACIÓN CON TU CSV MANUAL
            $csvPath = Join-Path $PSScriptRoot $nombreCsv
            $eventosNuevos = @()

            if (Test-Path $csvPath) {
                Write-Host "Leyendo CSV existente para comparar..." -ForegroundColor Gray
                # Importante: Usamos Delimiter ';' porque es lo que sale en tu imagen
                $csvData = Import-Csv -Path $csvPath -Delimiter ";" -Encoding UTF8
                $nombresAnteriores = $csvData.Nombre | ForEach-Object { $_.Trim(' "') } 

                $eventosNuevos = $listaEventos | Where-Object { 
                    $nombreLimpio = $_.Nombre.Trim(' "')
                    $nombreLimpio -notin $nombresAnteriores 
                }
                Write-Host "Eventos en API: $($listaEventos.Count) | Ya conocidos: $($nombresAnteriores.Count)" -ForegroundColor Gray
            } else {
                Write-Warning "No se encontró el archivo CSV en $csvPath. Se enviarán todos como nuevos."
                $eventosNuevos = $listaEventos
            }

            # SOBREESCRIBIMOS EL CSV con el formato limpio para la próxima vez
            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"

            # 6. ENVÍO TELEGRAM (Limpieza de ID para evitar Error 400)
            if ($eventosNuevos.Count -gt 0) {
                Write-Host "¡Novedades detectadas: $($eventosNuevos.Count)!" -ForegroundColor Magenta
                $token = $env:TELEGRAM_TOKEN
                $userFile = Join-Path $PSScriptRoot "usuarios_telegram.txt"
                
                if (Test-Path $userFile) {
                    # Limpiamos los IDs de cualquier formato extraño como @{id=...}
                    $chatIds = Get-Content $userFile | ForEach-Object { 
                        if ($_ -match '(\d+)') { $matches[1] } 
                    } | Select-Object -Unique

                    foreach ($ev in $eventosNuevos) {
                        $n = Escape-Html $ev.Nombre
                        $r = Escape-Html $ev.Recinto
                        $msg = "⚠️ <b>NUEVO EVENTO</b> ⚠️`n`n📌 <b>$n</b>`n📍 $r`n💰 $($ev.Precio)"
                        
                        foreach ($id in $chatIds) {
                            $payload = @{ chat_id = $id; text = $msg; parse_mode = "HTML" } | ConvertTo-Json
                            try {
                                Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" `
                                                  -Method Post -ContentType "application/json" -Body $payload
                                Write-Host "Enviado a $id" -ForegroundColor Gray
                            } catch {
                                Write-Warning "Error enviando a $id : $($_.Exception.Message)"
                            }
                        }
                        Start-Sleep -Milliseconds 500
                    }
                }
            } else {
                Write-Host "Sin novedades tras comparar con el CSV." -ForegroundColor Green
            }
        }
    }
    catch { Write-Error "Fallo general: $($_.Exception.Message)" }
    finally { if ($null -ne $driver) { $driver.Quit() } }
}

# Ejecución 5 veces
for ($i = 1; $i -le 5; $i++) {
    Write-Host "`n>>> EJECUCIÓN $i DE 5 <<<" -ForegroundColor Green
    MiFuncionPrincipal
    if ($i -lt 5) { Start-Sleep -Seconds 120 }
}
