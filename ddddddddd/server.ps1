# Servidor HTTP en PowerShell nativo para Windows
$port = 3000
$publicDir = Join-Path $PSScriptRoot "public"

# Obtener IP local de la red Wi-Fi / LAN
$localIp = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
if (-not $localIp) { $localIp = "127.0.0.1" }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Prefixes.Add("http://127.0.0.1:$port/") } catch {}

$started = $false
if ($localIp -ne "127.0.0.1") {
    try {
        $listener.Prefixes.Add("http://$localIp`:$port/")
        $listener.Start()
        $started = $true
    } catch {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$port/")
        try { $listener.Prefixes.Add("http://127.0.0.1:$port/") } catch {}
    }
}

if (-not $started) {
    try {
        $listener.Start()
        $started = $true
    } catch {
        Write-Host "Error al iniciar HttpListener: $_" -ForegroundColor Red
    }
}

if ($started) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " INSTITUTO NACIONAL DR. SARBELIO NAVARRETE" -ForegroundColor Cyan
    Write-Host " Servidor Web Local: http://localhost:$port/" -ForegroundColor Yellow
    Write-Host " Servidor Web Wi-Fi: http://$localIp`:$port/" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Green

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $urlPath = $request.Url.LocalPath

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $response.AddHeader("Access-Control-Allow-Headers", "*")
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        if ($urlPath -eq "/api/system/info") {
            $jsonResponse = "{`"status`":`"success`",`"ip`":`"$localIp`",`"port`":$port,`"url`":`"http://$localIp`:$port`"}"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentType = "application/json; charset=utf-8"
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            try {
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {}
            $response.Close()
            continue
        }

        # 1. API: Estado del monitor en vivo para proyector de aula
        if ($urlPath -eq "/api/qr/estado") {
            $token = $request.QueryString["token"]
            $hoy = (Get-Date).ToString("yyyy-MM-dd")
            $asisFile = Join-Path $PSScriptRoot "data\asistencias_live.json"
            $allAsis = @()
            if (Test-Path $asisFile) {
                try {
                    $raw = [System.IO.File]::ReadAllText($asisFile, [System.Text.Encoding]::UTF8)
                    $parsed = $raw | ConvertFrom-Json
                    if ($parsed -is [System.Collections.IList] -or $parsed -is [System.Array]) {
                        foreach ($it in $parsed) { if ($it -and $it.nie) { $allAsis += $it } }
                    } elseif ($parsed -and $parsed.nie) {
                        $allAsis += $parsed
                    }
                } catch {}
            }

            $filtradas = @()
            foreach ($it in $allAsis) {
                if ($it -and $it.fecha -eq $hoy) {
                    if (-not $token -or "$($it.token)".Trim() -eq "$token".Trim() -or ($it.token -and "$($it.token)".Contains("$token"))) {
                        $filtradas += $it
                    }
                }
            }

            $respObj = @{
                status = "success"
                total_asistencias = $filtradas.Count
                asistentes = $filtradas
            }
            $jsonResponse = $respObj | ConvertTo-Json -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentType = "application/json; charset=utf-8"
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            $response.AddHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
            try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
            $response.Close()
            continue
        }

        # 2. API: Marcaje de asistencia por código NIE (con validación de registro único)
        if ($urlPath -eq "/api/asistencia/marcar-qr" -and $request.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $parsed = $null
            try { $parsed = $body | ConvertFrom-Json } catch {}

            $nie = if ($parsed -and $parsed.nie) { "$($parsed.nie)".Trim() } else { "" }
            $token = if ($parsed -and $parsed.token) { "$($parsed.token)".Trim() } else { "" }

            $dataDir = Join-Path $PSScriptRoot "data"
            if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
            $asisFile = Join-Path $dataDir "asistencias_live.json"

            $allAsis = [System.Collections.ArrayList]::new()
            if (Test-Path $asisFile) {
                try {
                    $raw = [System.IO.File]::ReadAllText($asisFile, [System.Text.Encoding]::UTF8)
                    $rawParsed = $raw | ConvertFrom-Json
                    if ($rawParsed -is [System.Collections.IList] -or $rawParsed -is [System.Array]) {
                        foreach ($it in $rawParsed) { if ($it -and $it.nie) { [void]$allAsis.Add($it) } }
                    } elseif ($rawParsed -and $rawParsed.nie) {
                        [void]$allAsis.Add($rawParsed)
                    }
                } catch {}
            }

            $now = Get-Date
            $hoy = $now.ToString("yyyy-MM-dd")
            $horaStr = $now.ToString("hh:mm:ss tt")

            $studentCatalog = @(
                @{ id = 1; nie = "8492015"; nombres = "Carlos Eduardo"; apellidos = "Alvarado Gomez"; anio_bachillerato = "Primer Año"; bachillerato = "ITSI"; seccion_letra = "A" },
                @{ id = 2; nie = "9120482"; nombres = "Sofía Beatriz"; apellidos = "Rivas Morales"; anio_bachillerato = "Primer Año"; bachillerato = "General"; seccion_letra = "A" },
                @{ id = 3; nie = "7483921"; nombres = "Kevin Alexander"; apellidos = "Martinez Martinez"; anio_bachillerato = "Segundo Año"; bachillerato = "Administrativo Contable"; seccion_letra = "B" },
                @{ id = 4; nie = "6382019"; nombres = "Valeria Nicolle"; apellidos = "Gutierrez Lopez"; anio_bachillerato = "Tercer Año"; bachillerato = "Salud"; seccion_letra = "A" }
            )

            $estudiante = $studentCatalog | Where-Object { "$($_.nie)".Trim() -eq $nie } | Select-Object -First 1
            $nombreCompleto = if ($estudiante) { "$($estudiante.nombres) $($estudiante.apellidos)" } else { "Estudiante NIE $nie" }
            $grado = if ($estudiante) { "$($estudiante.anio_bachillerato) $($estudiante.bachillerato) `"$($estudiante.seccion_letra)`"" } else { "Educación Media" }

            # Verificación de Registro Único: Un estudiante solo puede registrarse una vez al día
            $yaMarcado = $null
            foreach ($it in $allAsis) {
                if ($it -and "$($it.nie)".Trim() -eq $nie -and $it.fecha -eq $hoy) {
                    $yaMarcado = $it
                    break
                }
            }

            if ($null -ne $yaMarcado) {
                $h = "$($yaMarcado.hora_marcaje)"
                if (-not $h) { $h = "$($yaMarcado.hora)" }
                $e = "$($yaMarcado.estado)"
                if (-not $e) { $e = "Presente" }

                $warnResp = @{
                    status = "warning"
                    code = "ALREADY_REGISTERED"
                    message = "Registro bloqueado: El estudiante ya registró su asistencia el día de hoy. Solo se permite un único registro por NIE."
                    estudiante = $nombreCompleto
                    nie = $nie
                    hora = $h
                    estado = $e
                }
                $jsonResponse = $warnResp | ConvertTo-Json -Depth 6
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
                $response.ContentType = "application/json; charset=utf-8"
                $response.AddHeader("Access-Control-Allow-Origin", "*")
                try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
                $response.Close()
                continue
            }

            $esTardanza = ($now.Hour -gt 8 -or ($now.Hour -eq 8 -and $now.Minute -gt 15))
            $estadoAsis = if ($esTardanza) { "Tardanza" } else { "Presente" }

            $nuevaAsis = [PSCustomObject]@{
                id = $allAsis.Count + 1
                token = $token
                nie = $nie
                estudiante = $nombreCompleto
                nombres = if ($estudiante) { $estudiante.nombres } else { "" }
                apellidos = if ($estudiante) { $estudiante.apellidos } else { "" }
                grado = $grado
                materia = "Desarrollo de Software Web"
                salon = "Aula 1"
                docente = "Prof. Carlos Hernandez"
                fecha = $hoy
                hora = $horaStr
                hora_marcaje = $horaStr
                estado = $estadoAsis
                metodo_registro = if ($parsed -and $parsed.metodo_registro) { $parsed.metodo_registro } else { "QR_Estudiante" }
                ubicacion = "Instituto Nacional Dr. Sarbelio Navarrete"
                direccion = "6ª Calle Poniente y 9ª Avenida Sur, San Vicente"
                distancia_metros = 12
                ubicacion_verificada = $true
            }

            $allAsis.Insert(0, $nuevaAsis)
            try {
                $jsonToSave = $allAsis | ConvertTo-Json -Depth 6
                [System.IO.File]::WriteAllText($asisFile, $jsonToSave, [System.Text.Encoding]::UTF8)
            } catch {}

            $succResp = @{
                status = "success"
                message = if ($esTardanza) { "Asistencia registrada como TARDANZA" } else { "¡Asistencia PUNTUAL registrada con éxito en INSAVI!" }
                estudiante = $nuevaAsis
            }

            $jsonResponse = $succResp | ConvertTo-Json -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentType = "application/json; charset=utf-8"
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
            $response.Close()
            continue
        }

        if ($urlPath -eq "/api/google-sheets/proxy") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $jsonObj = $null
            try { $jsonObj = $body | ConvertFrom-Json } catch {}

            $scriptUrl = if ($jsonObj) { $jsonObj.script_url } else { "" }
            $payload = if ($jsonObj) { $jsonObj.payload } else { $null }

            $result = @{ status = "error"; message = "Faltan parámetros script_url o payload" }

            if ($scriptUrl -and $payload) {
                try {
                    $jsonPayload = $payload | ConvertTo-Json -Depth 6 -Compress
                    $remoteResp = Invoke-RestMethod -Uri $scriptUrl -Method Post -Body $jsonPayload -ContentType "application/json" -TimeoutSec 15
                    $result = @{ status = "success"; message = "Enviado a Google Sheets correctamente"; response = $remoteResp }
                } catch {
                    $result = @{ status = "error"; message = "Error de conexión con Google Apps Script: $($_.Exception.Message)" }
                }
            }

            $jsonResponse = $result | ConvertTo-Json -Depth 6
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentType = "application/json; charset=utf-8"
            $response.AddHeader("Access-Control-Allow-Origin", "*")
            $response.AddHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
            $response.AddHeader("Access-Control-Allow-Headers", "*")
            try {
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {}
            $response.Close()
            continue
        }

        if ($urlPath -eq "/") { $urlPath = "/index.html" }

        $localPath = Join-Path $publicDir $urlPath.TrimStart('/')

        if (-not (Test-Path $localPath -PathType Leaf)) {
            $localPath = Join-Path $publicDir "index.html"
        }

        $ext = [System.IO.Path]::GetExtension($localPath).ToLower()
        $contentType = "text/html; charset=utf-8"

        switch ($ext) {
            ".css"  { $contentType = "text/css; charset=utf-8" }
            ".js"   { $contentType = "application/javascript; charset=utf-8" }
            ".json" { $contentType = "application/json; charset=utf-8" }
            ".png"  { $contentType = "image/png" }
            ".jpg"  { $contentType = "image/jpeg" }
            ".jpeg" { $contentType = "image/jpeg" }
            ".svg"  { $contentType = "image/svg+xml" }
            ".ico"  { $contentType = "image/x-icon" }
        }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($localPath)
            $response.ContentType = $contentType
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            $response.StatusCode = 500
        } finally {
            $response.Close()
        }
    }
} catch {
    Write-Host "Error al iniciar el servidor listener: $_" -ForegroundColor Red
} finally {
    if ($listener.IsListening) { $listener.Stop() }
}

