#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# ============================================================
#  Walhalla Twitch Stream Monitor - Touch Portal Plugin
#  by odin23x
# ============================================================

$PluginId    = 'odin23x.walhalla_twitch_stream_monitor'
$PluginDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$StreamersFile = Join-Path $PluginDir 'streamers.txt'
$LogFile     = Join-Path $PluginDir 'monitor.log'
$TPHost      = '127.0.0.1'
$TPPort      = 12136
$MaxLogLines = 500

$script:Settings = @{
    'Twitch Client ID'           = ''
    'Twitch User Access Token'   = ''
    'Update Interval Seconds'    = '120'
    'Max Slots'                  = '10'
}

$script:TcpClient      = $null
$script:Writer         = $null
$script:Reader         = $null
$script:AutoUpdate     = $true
$script:ForceRefresh   = $false
$script:LastCheckUtc   = [datetime]::MinValue
$script:LastStates     = @{}

# ============================================================
#  Logging
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Message
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        # Keep log trimmed
        $lines = @(Get-Content -Path $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $MaxLogLines) {
            $lines[-$MaxLogLines..-1] | Set-Content -Path $LogFile -Encoding UTF8
        }
    } catch {}
    Write-Host $line
}

# ============================================================
#  Touch Portal Communication
# ============================================================
function Send-TP {
    param([hashtable]$Payload)
    if ($null -eq $script:Writer) { return }
    try {
        $json = $Payload | ConvertTo-Json -Compress -Depth 10
        $script:Writer.WriteLine($json)
        $script:Writer.Flush()
    } catch { Write-Log "Send-TP error: $($_.Exception.Message)" 'WARN' }
}

function Set-State {
    param([string]$Id, [string]$Value)
    # Only send if value changed to reduce TP traffic
    if ($script:LastStates[$Id] -eq $Value) { return }
    $script:LastStates[$Id] = $Value
    Send-TP @{ type = 'stateUpdate'; id = $Id; value = [string]$Value }
}

function Set-States-Batch {
    param([System.Collections.Generic.List[hashtable]]$States)
    foreach ($s in $States) {
        Set-State $s.id $s.value
    }
}

# ============================================================
#  Settings Helpers
# ============================================================
function Parse-SettingsArray {
    param($Values)
    foreach ($item in $Values) {
        foreach ($prop in $item.PSObject.Properties) {
            $script:Settings[$prop.Name] = [string]$prop.Value
        }
    }
}

function Get-IntervalSeconds {
    $v = 120
    [void][int]::TryParse([string]$script:Settings['Update Interval Seconds'], [ref]$v)
    if ($v -lt 30)   { $v = 30 }
    if ($v -gt 3600) { $v = 3600 }
    return $v
}

function Get-MaxSlots {
    $v = 10
    [void][int]::TryParse([string]$script:Settings['Max Slots'], [ref]$v)
    if ($v -lt 1)  { $v = 1 }
    if ($v -gt 10) { $v = 10 }
    return $v
}

# ============================================================
#  Streamers File
# ============================================================
function Read-StreamersList {
    if (-not (Test-Path $StreamersFile)) {
        Set-Content -Path $StreamersFile -Value "# Einen Streamer-Login pro Zeile eintragen`n# Zeilen mit # werden ignoriert`n# Beispiele:`n# xqc`n# pokimane`n# summit1g" -Encoding UTF8
        return @()
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -Path $StreamersFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $clean = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean.StartsWith('#')) { continue }
        $list.Add($clean.ToLowerInvariant())
    }
    # Deduplicate, preserve order
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($s in $list) {
        if (-not $seen.ContainsKey($s)) { $seen[$s] = $true; $result.Add($s) }
    }
    return @($result)
}

function Open-StreamersFile {
    try {
        if (-not (Test-Path $StreamersFile)) { Read-StreamersList | Out-Null }
        Start-Process notepad.exe -ArgumentList $StreamersFile
    } catch { Write-Log "Could not open streamers file: $($_.Exception.Message)" 'WARN' }
}

# ============================================================
#  Twitch API
# ============================================================
function Invoke-TwitchApi {
    param([string]$Url)
    $clientId = [string]$script:Settings['Twitch Client ID']
    $token    = [string]$script:Settings['Twitch User Access Token']
    $token    = $token -replace '^oauth:', ''
    $headers  = @{ 'Client-Id' = $clientId; 'Authorization' = "Bearer $token" }
    return Invoke-RestMethod -Uri $Url -Method Get -Headers $headers -ContentType 'application/json' -ErrorAction Stop
}

function Get-LiveStreams {
    param([string[]]$Logins)
    if ($Logins.Count -eq 0) { return @{} }

    $map = @{}
    # Batch in groups of 100
    $i = 0
    while ($i -lt $Logins.Count) {
        $batch = $Logins[$i..([Math]::Min($i + 99, $Logins.Count - 1))]
        $query = ($batch | ForEach-Object { "user_login=$([uri]::EscapeDataString($_))" }) -join '&'
        $resp  = Invoke-TwitchApi -Url "https://api.twitch.tv/helix/streams?$query&first=100"
        foreach ($stream in $resp.data) {
            $map[$stream.user_login.ToLowerInvariant()] = $stream
        }
        $i += 100
    }
    return $map
}

function Get-UserInfoBatch {
    param([string[]]$Logins)
    if ($Logins.Count -eq 0) { return @{} }
    $map = @{}
    $i = 0
    while ($i -lt $Logins.Count) {
        $batch = $Logins[$i..([Math]::Min($i + 99, $Logins.Count - 1))]
        $query = ($batch | ForEach-Object { "login=$([uri]::EscapeDataString($_))" }) -join '&'
        $resp  = Invoke-TwitchApi -Url "https://api.twitch.tv/helix/users?$query"
        foreach ($u in $resp.data) {
            $map[$u.login.ToLowerInvariant()] = $u
        }
        $i += 100
    }
    return $map
}

function Format-Uptime {
    param([string]$StartedAt)
    try {
        $start = [datetime]::Parse($StartedAt).ToUniversalTime()
        $span  = [datetime]::UtcNow - $start
        if ($span.TotalHours -ge 1) {
            return '{0}h {1}m' -f [math]::Floor($span.TotalHours), $span.Minutes
        }
        return '{0}m' -f $span.Minutes
    } catch { return '' }
}

# ============================================================
#  Clear Slot
# ============================================================
function Clear-Slot {
    param([int]$Slot)
    $pfx = "$PluginId.state.slot_$Slot"
    Set-State "$pfx.user_name"    ''
    Set-State "$pfx.game_name"    ''
    Set-State "$pfx.title"        ''
    Set-State "$pfx.viewer_count" ''
    Set-State "$pfx.is_live"      'FALSE'
    Set-State "$pfx.uptime"       ''
    Set-State "$pfx.is_mature"    'FALSE'
}

# ============================================================
#  Main Check
# ============================================================
function Run-Check {
    $clientId = [string]$script:Settings['Twitch Client ID']
    $token    = [string]$script:Settings['Twitch User Access Token']

    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($token)) {
        Set-State "$PluginId.state.summary.status" 'Bitte Client ID und Token eintragen'
        return
    }

    Set-State "$PluginId.state.summary.status" 'Wird aktualisiert...'

    try {
        $streamers = @(Read-StreamersList)
        $maxSlots  = Get-MaxSlots
        $capped    = @($streamers | Select-Object -First $maxSlots)

        Set-State "$PluginId.state.summary.total_count" [string]$capped.Count

        if ($capped.Count -eq 0) {
            Set-State "$PluginId.state.summary.online_count" '0'
            Set-State "$PluginId.state.summary.status" 'streamers.txt ist leer'
            1..$maxSlots | ForEach-Object { Clear-Slot $_ }
            $script:LastCheckUtc = [datetime]::UtcNow
            return
        }

        Write-Log "Checking $($capped.Count) streamer(s)..."

        $liveMap = Get-LiveStreams -Logins $capped
        $onlineCount = 0

        for ($i = 0; $i -lt $capped.Count; $i++) {
            $slot    = $i + 1
            $login   = $capped[$i]
            $pfx     = "$PluginId.state.slot_$slot"
            $stream  = $liveMap[$login]

            if ($null -ne $stream) {
                $onlineCount++
                $uptime = Format-Uptime -StartedAt $stream.started_at
                Set-State "$pfx.user_name"    ([string]$stream.user_name)
                Set-State "$pfx.game_name"    ([string]$stream.game_name)
                Set-State "$pfx.title"        ([string]$stream.title)
                Set-State "$pfx.viewer_count" ([string]$stream.viewer_count)
                Set-State "$pfx.is_live"      'TRUE'
                Set-State "$pfx.uptime"       $uptime
                Set-State "$pfx.is_mature"    (if ($stream.is_mature) { 'TRUE' } else { 'FALSE' })
            } else {
                Set-State "$pfx.user_name"    $login
                Set-State "$pfx.game_name"    ''
                Set-State "$pfx.title"        ''
                Set-State "$pfx.viewer_count" ''
                Set-State "$pfx.is_live"      'FALSE'
                Set-State "$pfx.uptime"       ''
                Set-State "$pfx.is_mature"    'FALSE'
            }
        }

        # Clear unused slots
        if ($capped.Count -lt $maxSlots) {
            ($capped.Count + 1)..$maxSlots | ForEach-Object { Clear-Slot $_ }
        }

        Set-State "$PluginId.state.summary.online_count" [string]$onlineCount
        Set-State "$PluginId.state.summary.last_update"  ([datetime]::Now.ToString('dd.MM.yyyy HH:mm:ss'))
        Set-State "$PluginId.state.summary.status"       'OK'
        Write-Log "Check done. $onlineCount/$($capped.Count) online."

        $script:LastCheckUtc = [datetime]::UtcNow

    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg += ' | ' + $_.ErrorDetails.Message }
        Set-State "$PluginId.state.summary.status" "Fehler: $msg"
        Write-Log "Run-Check failed: $msg" 'ERROR'
    }
}

# ============================================================
#  Message Handler
# ============================================================
function Handle-Message {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $msg = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return }

    switch ([string]$msg.type) {
        'info' {
            if ($null -ne $msg.settings) { Parse-SettingsArray -Values $msg.settings }
            Set-State "$PluginId.state.summary.autoupdate" (if ($script:AutoUpdate) { 'AN' } else { 'AUS' })
            $script:ForceRefresh = $true
        }
        'settings' {
            if ($null -ne $msg.values) { Parse-SettingsArray -Values $msg.values }
            $script:LastStates   = @{}
            $script:ForceRefresh = $true
        }
        'action' {
            switch ([string]$msg.actionId) {
                "$PluginId.act.refresh"         { $script:ForceRefresh = $true }
                "$PluginId.act.toggle_autoupdate" {
                    $script:AutoUpdate = -not $script:AutoUpdate
                    Set-State "$PluginId.state.summary.autoupdate" (if ($script:AutoUpdate) { 'AN' } else { 'AUS' })
                    Write-Log "AutoUpdate: $(if ($script:AutoUpdate) { 'AN' } else { 'AUS' })"
                }
                "$PluginId.act.open_file" { Open-StreamersFile }
            }
        }
        'closePlugin' { throw 'Touch Portal requested plugin shutdown.' }
    }
}

# ============================================================
#  TCP Connection
# ============================================================
function Connect-TouchPortal {
    while ($true) {
        try {
            $script:TcpClient = New-Object System.Net.Sockets.TcpClient
            $script:TcpClient.Connect($TPHost, $TPPort)
            $stream          = $script:TcpClient.GetStream()
            $enc             = New-Object System.Text.UTF8Encoding($false)
            $script:Writer   = New-Object System.IO.StreamWriter($stream, $enc)
            $script:Writer.AutoFlush = $true
            $script:Reader   = New-Object System.IO.StreamReader($stream, $enc)
            Send-TP @{ type = 'pair'; id = $PluginId }
            Write-Log 'Connected to Touch Portal.'
            return
        } catch {
            Write-Log "Connection failed, retrying in 5s: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds 5
        }
    }
}

# ============================================================
#  Init
# ============================================================
Write-Log '=== Walhalla Twitch Stream Monitor starting ==='

# Ensure streamers.txt exists
if (-not (Test-Path $StreamersFile)) { Read-StreamersList | Out-Null }

Connect-TouchPortal

Set-State "$PluginId.state.summary.status"       'Startet...'
Set-State "$PluginId.state.summary.online_count" '0'
Set-State "$PluginId.state.summary.total_count"  '0'
Set-State "$PluginId.state.summary.autoupdate"   'AN'
Set-State "$PluginId.state.summary.last_update"  '-'

# ============================================================
#  Main Loop
# ============================================================
while ($true) {
    try {
        # Process incoming TP messages
        while ($script:TcpClient.Available -gt 0 -or $script:Reader.Peek() -ge 0) {
            $line = $script:Reader.ReadLine()
            if ($null -eq $line) { break }
            Handle-Message -Line $line
        }

        # Check if update is due
        $interval = Get-IntervalSeconds
        $elapsed  = ([datetime]::UtcNow - $script:LastCheckUtc).TotalSeconds

        $shouldRun = $script:ForceRefresh -or
                     $script:LastCheckUtc -eq [datetime]::MinValue -or
                     ($script:AutoUpdate -and $elapsed -ge $interval)

        if ($shouldRun) {
            $script:ForceRefresh = $false
            Run-Check
        }

        # Show countdown when autoupdate is active
        if ($script:AutoUpdate -and $script:LastCheckUtc -ne [datetime]::MinValue) {
            $remaining = [math]::Max(0, $interval - [int]$elapsed)
            Set-State "$PluginId.state.summary.next_update" "${remaining}s"
        } else {
            Set-State "$PluginId.state.summary.next_update" '-'
        }

        Start-Sleep -Milliseconds 500

    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -eq 'Touch Portal requested plugin shutdown.') {
            Write-Log 'Shutdown requested. Exiting.'
            exit 0
        }
        Write-Log "Main loop error, reconnecting: $errMsg" 'ERROR'
        try { Set-State "$PluginId.state.summary.status" 'Verbindung unterbrochen...' } catch {}
        Start-Sleep -Seconds 3
        foreach ($obj in @($script:Reader, $script:Writer, $script:TcpClient)) {
            try { if ($obj) { $obj.Dispose() } } catch {}
        }
        $script:Reader = $null; $script:Writer = $null; $script:TcpClient = $null
        Connect-TouchPortal
    }
}
