[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Rutas y Variables
$nugetFolder = "C:\powershell\SeleniumFiles"
$dllPath = "$nugetFolder\lib\webdrivernetstandard2.0\WebDriver.dll"
$driverPath = "$nugetFolder\manager\windows"

$urlPagina = "https://tickets.oneboxtds.com/abonoteatro/events"
# URL CORREGIDA: Traemos eventos reales (onCarousel=false) y límite de 50
$urlApi = "https://tickets.oneboxtds.com/channels-api/v1/catalog/events?limit=50&offset=0&sort=customOrder%3Aasc&onCarousel=false&channel=abonoteatro"

Add-Type -Path $dllPath


function MiFuncionPrincipal {
    $options = [OpenQA.Selenium.Chrome.ChromeOptions]::new()
    $uAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    $options.AddArgument("--window-size=1920,1080")
    $options.AddArgument("--user-agent=$uAgent")
    # Descomenta la siguiente línea si quieres que sea invisible tras comprobar que funciona
    # $options.AddArgument("--headless=new") 
    try {
        Write-Host "--- Iniciando Validación Cloudflare ---" -ForegroundColor Cyan
        $driver = [OpenQA.Selenium.Chrome.ChromeDriver]::new($driverPath, $options)

        $driver.Navigate().GoToUrl($urlPagina)
        Write-Host "Esperando aviso de cookies..." -ForegroundColor Yellow
        Start-Sleep -Seconds 6

        # 2. INTERACTUAR CON EL BOTÓN DE COOKIES
        try {
            $botonAceptar = $driver.FindElement([OpenQA.Selenium.By]::XPath("//button[contains(., 'Aceptar Todas')]"))
            if ($botonAceptar) {
                Write-Host "Pulsando 'Aceptar Todas' para desbloquear sesión..." -ForegroundColor Green
                $botonAceptar.Click()
                Start-Sleep -Seconds 5 # Tiempo vital para que Cloudflare genere el ticket cf_clearance
            }
        }
        catch {
            Write-Warning "No se detectó botón de cookies."
        }

        # 3. CREAR SESIÓN DE POWERSHELL Y CAPTURAR COOKIES
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = $uAgent

        $cookiesSelenium = $driver.Manage().Cookies.AllCookies
        foreach ($c in $cookiesSelenium) {
            
                $newCookie = New-Object System.Net.Cookie($c.Name, $c.Value, "/", ".proticketing.com")
                $session.Cookies.Add($newCookie)
                Write-Host "Capturada: $($c.Name)" -ForegroundColor Gray
            
        }

        # Cerramos navegador
        $driver.Quit()
        

        # 5. LLAMADA A LA API CON HEADERS DINÁMICOS
        Write-Host "Consultando API Proticketing..." -ForegroundColor Cyan
        
        $headers = @{
            "Accept"           = "application/json, text/plain, */*"
            "Referer"          = $urlPagina
            "ob-channel-id"    = "553"
            "ob-client"        = "channels"
            "ob-language"      = "es-ES"
            "ob-session-token" = $dynamicToken # <--- USAMOS EL TOKEN QUE ACABAMOS DE ROBAR
        }

        $response = Invoke-RestMethod -Uri $urlApi -WebSession $session -Headers $headers

        # 6. PROCESAMIENTO DE EVENTOS
        if ($response.data) {
            Write-Host "¡Éxito! $($response.data.Count) eventos recibidos." -ForegroundColor Green
            
            $listaEventos = foreach ($e in $response.data) {
                # Extraer precio de forma segura
                $precio = if ($e.minimumPrice) { "$($e.minimumPrice) EUR" } else { "Consultar" }

                [PSCustomObject]@{
                    Nombre  = $e.name
                    Cuando  = "Desde: $($e.date.start) Hasta: $($e.date.end)"
                    Precio  = $precio
                    Recinto = $e.venues[0].name
                }
            }

            # 7. GESTIÓN DE CSV Y NOVEDADES
            $csvPath = "C:\temp\eventos_abonoteatro_proticketing.csv"
            
            $eventosNuevos = @()
            if (Test-Path $csvPath) {
                $eventosAnteriores = Import-Csv $csvPath -Delimiter ";"
                $nombresAnteriores = $eventosAnteriores.Nombre
                $eventosNuevos = $listaEventos | Where-Object { $_.Nombre -notin $nombresAnteriores }
            } else {
                $eventosNuevos = $listaEventos
            }

            $listaEventos | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
            
        } else {
            Write-Host "No se han conseguido datos de la API." -ForegroundColor Red
        }

        # 8. TELEGRAM (Solo si hay novedades)
        if ($eventosNuevos.Count -gt 0) {
            Write-Host "Hay $($eventosNuevos.Count) eventos nuevos. Enviando a Telegram..." -ForegroundColor Magenta
            
            $telegramToken = $env:TELEGRAM_TOKEN
            $archivoUsuarios = Join-Path $PSScriptRoot "usuarios_telegram.txt"
            
            # Obtener IDs de Telegram de forma limpia
            $chatIds = Get-Content $archivoUsuarios | ForEach-Object { 
                if ($_ -match '(\d+)') { $matches[1] } 
            } | Select-Object -Unique

            foreach ($nuevo in $eventosNuevos) {
                foreach ($chatId in $chatIds) {
                    $texto = "⚠️ <b>NUEVO EVENTO ABONOTEATRO - ATENTOS</b> ⚠️`n`n" +
                            "📌 <b>$($nuevo.Nombre)</b>`n" +
                            "📍 Recinto: $($nuevo.Recinto)`n" +
                            "💰 Precio: $($nuevo.Precio)`n" +
                            "📅 $($nuevo.Cuando)"

                    $body = @{
                        chat_id = $chatId
                        text    = $texto
                        parse_mode = "HTML"
                    }
                    
                    try {
                        #write-host $eventosNuevos
                        Invoke-RestMethod -Uri "https://api.telegram.org/bot$telegramToken/sendMessage" -Method Post -Body $body
                    } catch {
                        Write-Warning "No se pudo enviar mensaje al chat $chatId"
                    }
                }
            }
        } else {
            $ultimaHora = Get-Date -Format "HH:mm:ss"
            Write-Host "Sin cambios desde la última ejecución: $ultimaHora" -ForegroundColor Blue
        }
    }
    catch {
        Write-Error "Fallo general: $($_.Exception.Message)"
        if ($driver) { $driver.Quit() }
    }
}

function Iniciar-CuentaAtras {
    param([int]$segundosTotales)
    
    for ($i = $segundosTotales; $i -gt 0; $i--) {
        # Calculamos minutos y segundos para que se vea como 04:59, 04:58...
        $tiempo = New-TimeSpan -Seconds $i
        $reloj = "{0:D2}:{1:D2}" -f $tiempo.Minutes, $tiempo.Seconds
        
        # `r vuelve al inicio de la línea para sobrescribir el texto anterior
        Write-Host -NoNewline "`rPróxima ejecución en: $reloj " -ForegroundColor Gray
        
        Start-Sleep -Seconds 1
    }
    # Limpiamos la línea al terminar la cuenta atrás
    Write-Host "`r" + (" " * 30) + "`r" -NoNewline
}

# 3. Bucle infinito
while ($true) {
    # Ejecutamos la tarea
    MiFuncionPrincipal
    
    # Iniciamos la espera de 5 minutos (300 segundos)
    Iniciar-CuentaAtras -segundosTotales 300
}
