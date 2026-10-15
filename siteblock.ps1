# SiteBlock for Windows: blocks sites for every browser via the hosts file + browser policies.
# A SYSTEM scheduled task ("enforce") re-applies both every 2 seconds and runs pending unblocks.
param([string]$Cmd = 'status', [string]$Arg, [switch]$WholeSite)

$ErrorActionPreference = 'Stop'
$Dir      = "$env:ProgramData\SiteBlock"
$State    = "$Dir\state.json"
$Bin      = "$env:ProgramFiles\SiteBlock"
$Hosts    = "$env:SystemRoot\System32\drivers\etc\hosts"
$Begin    = '# BEGIN SiteBlock'
$End      = '# END SiteBlock'
$Task     = 'SiteBlock'
$Lnk      = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\SiteBlock.lnk"
$Chromium = 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$Firefox  = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'

# ponytail: countdowns use the wall clock, so changing the system time skips a wait (needs admin anyway).
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Dur($sec) { $t = [TimeSpan]::FromSeconds([math]::Max(0, $sec)); '{0}h {1}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
function Secs($t) { if ($t -match '^(\d+)([mh]?)$') { [int]$matches[1] * $(if ($matches[2] -eq 'h') { 3600 } else { 60 }) } else { throw 'Use e.g. 30m or 2h' } }
function Log($m) { Add-Content "$Dir\siteblock.log" "$(Get-Date -Format s) $m" }

# "https://www.YouTube.com/shorts/x?y" -> "youtube.com/shorts/x"
function Normalize([string]$s) {
    $s = $s.Trim().ToLower() -replace '^[a-z]+://', '' -replace '[?#].*$', ''
    $h, $p = $s -split '/', 2
    $h = $h -replace ':\d+$', '' -replace '^www\.', ''
    if ($h -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw "Not a site: $s" }
    if ($p) { $p = $p.TrimEnd('/') }
    if ($p) { "$h/$p" } else { $h }
}

# ponytail: only www./m. variants; add per-site extras (youtu.be, ytimg.com...) if hosts-only browsers leak.
function HostNames($sites) { foreach ($n in $sites) { if ($n -notlike '*/*') { $n; "www.$n"; "m.$n" } } }

# Drops our old section and any other line pointing a blocked name somewhere, then appends our section.
function BuildHosts([string]$text, $names) {
    $out = New-Object Collections.Generic.List[string]; $in = $false
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -eq $Begin) { $in = $true } elseif ($l -eq $End) { $in = $false }
        elseif (-not $in) {
            $onLine = @(($l -replace '#.*').Trim() -split '\s+' | Select-Object -Skip 1)
            if (-not ($onLine | Where-Object { $names -contains $_ })) { $out.Add($l) }
        }
    }
    while ($out.Count -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($names) { $out.Add($Begin); foreach ($n in $names) { $out.Add("0.0.0.0 $n"); $out.Add(":: $n") }; $out.Add($End) }
    ($out -join "`r`n") + "`r`n"
}

function Fix-Hosts($names) {
    $cur = if (Test-Path $Hosts) { [IO.File]::ReadAllText($Hosts) } else { '' }
    $new = BuildHosts $cur $names
    if ($new -ceq $cur) { return }
    if (Test-Path $Hosts) { (Get-Item $Hosts -Force).Attributes = 'Normal' }   # undo read-only
    [IO.File]::WriteAllText($Hosts, $new)
    Clear-DnsClientCache
    Log 'hosts file repaired'
}

function Set-List($key, $vals) {
    $cur = if (Test-Path $key) { $i = Get-Item $key; @($i.GetValueNames() | Sort-Object { [int]$_ } | ForEach-Object { $i.GetValue($_) }) } else { $null }
    if ($null -ne $cur -and ($cur -join "`n") -ceq (@($vals) -join "`n")) { return }
    if (Test-Path $key) { Remove-Item $key -Recurse }
    New-Item $key -Force | Out-Null
    $n = 1; foreach ($v in $vals) { New-ItemProperty $key -Name ($n++) -Value $v -PropertyType String | Out-Null }
}

function Set-Val($key, $name, $val, $type) {
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    if ((Get-ItemProperty $key -ErrorAction SilentlyContinue).$name -ne $val) { New-ItemProperty $key -Name $name -Value $val -PropertyType $type -Force | Out-Null }
}

# Chrome/Edge/Brave URLBlocklist understands "site.com" (incl. subdomains) and "site.com/path" (prefix).
# Secure DNS is switched off so browsers can't resolve around the hosts file.
function Fix-Policies($sites) {
    foreach ($k in $Chromium) { Set-List "$k\URLBlocklist" $sites; Set-Val $k DnsOverHttpsMode 'off' String }
    $ff = foreach ($n in $sites) { $h, $p = $n -split '/', 2; if ($p) { "*://$h/$p*"; "*://*.$h/$p*" } else { "*://$h/*"; "*://*.$h/*" } }
    Set-List "$Firefox\WebsiteFilter\Block" $ff
    Set-Val "$Firefox\DNSOverHTTPS" Enabled 0 DWord
    Set-Val "$Firefox\DNSOverHTTPS" Locked 1 DWord
}

function Remove-All {
    Fix-Hosts @()
    foreach ($k in $Chromium) { Remove-Item "$k\URLBlocklist" -Recurse -ErrorAction SilentlyContinue; Remove-ItemProperty $k DnsOverHttpsMode -ErrorAction SilentlyContinue }
    Remove-Item "$Firefox\WebsiteFilter", "$Firefox\DNSOverHTTPS" -Recurse -ErrorAction SilentlyContinue
    $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    [Environment]::SetEnvironmentVariable('Path', (($p -split ';' | Where-Object { $_ -and $_ -ne $Bin }) -join ';'), 'Machine')
    Unregister-ScheduledTask $Task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $Bin, $Dir, $Lnk -Recurse -Force -ErrorAction SilentlyContinue
}

# --- state (CLI and enforcer share it under a global mutex) ---
function Lock([scriptblock]$b) {
    $m = New-Object Threading.Mutex($false, 'Global\SiteBlock')
    try { [void]$m.WaitOne() } catch [Threading.AbandonedMutexException] {}
    try { & $b } finally { $m.ReleaseMutex(); $m.Dispose() }
}
function Load {   # locked too, so a read never meets a half-done write (the mutex is re-entrant inside Edit)
    Lock {
        if (Test-Path $State) { return Get-Content $State -Raw | ConvertFrom-Json }
        [pscustomobject]@{ hash = $null; salt = $null; delay = 1800; pendingDelay = $null; sites = @(); uninstallAt = $null; recoverAt = $null; fails = 0; lockUntil = 0 }
    }
}
function Save($s) { $s | ConvertTo-Json -Depth 5 | Set-Content $State -Encoding UTF8 }
function Edit([scriptblock]$f) { Lock { $s = Load; $r = & $f $s; Save $s; $r } }

# --- password ---
function ReadPw($prompt) { $ss = Read-Host $prompt -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)) }
function Hash($pw, $salt) {
    $k = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, [Convert]::FromBase64String($salt), 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    [Convert]::ToBase64String($k.GetBytes(32))
}
function Check-Pw($s, $pw) {   # returns an error message, or nothing when the password is right
    if (-not $s.hash) { return 'No password set; run: siteblock passwd' }
    if ((Now) -lt $s.lockUntil) { return "Too many wrong passwords; try again in $(Dur ($s.lockUntil - (Now)))." }
    if ((Hash $pw $s.salt) -ceq $s.hash) { $s.fails = 0; return }
    $s.fails++; if ($s.fails -ge 5) { $s.fails = 0; $s.lockUntil = (Now) + 900 }
    'Wrong password.'
}
function New-Pw {
    $a = ReadPw 'New SiteBlock password (store it somewhere safe; it cannot be shown again)'
    if (-not $a -or $a -cne (ReadPw 'Repeat it')) { throw 'Passwords empty or did not match.' }
    $b = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $salt = [Convert]::ToBase64String($b); $h = Hash $a $salt
    Edit { param($s) $s.salt = $salt; $s.hash = $h; $s.fails = 0 } | Out-Null
}
function Authed([scriptblock]$then) {   # ask password outside the lock, then check + act atomically
    $pw = ReadPw 'SiteBlock password'
    $err = Edit { param($s) $e = Check-Pw $s $pw; if (-not $e) { & $then $s | Out-Null }; $e }
    if ($err) { throw $err }
}

function SiteStatus($x) { if ($x.unblockAt) { "Still blocked, opens in $(Dur ($x.unblockAt - (Now)))" } else { 'Blocked' } }
function Summary {
    $s = Load; $now = Now
    "Unblock delay: $(Dur $s.delay)" + $(if ($s.pendingDelay) { " (becomes $(Dur $s.pendingDelay.value) in $(Dur ($s.pendingDelay.at - $now)))" })
    if ($s.uninstallAt) { "Uninstall in $(Dur ($s.uninstallAt - $now))" }
    if ($s.recoverAt) { "Password reset in $(Dur ($s.recoverAt - $now))" }
    # Get-ScheduledTask can't parse the task's endless repetition (0x80041318); Get-ScheduledTaskInfo can.
    if (-not (Get-ScheduledTaskInfo $Task -ErrorAction SilentlyContinue)) { 'WARNING: enforcer task is missing; run install again.' }
}
function Status {
    $s = Load
    if (-not @($s.sites).Count) { 'Nothing blocked.' }
    foreach ($x in $s.sites) { "$($x.name)  $(SiteStatus $x)" }
    Summary
}

# --- actions shared by the CLI and the GUI; each returns the normalized site name ---
function Add-Site($site, [switch]$Whole) {
    $n = Normalize $site; if ($Whole) { $n = ($n -split '/')[0] }
    if (-not (Load).hash) { New-Pw }
    Edit { param($s) if (@($s.sites | ForEach-Object { $_.name }) -notcontains $n) { $s.sites = @($s.sites) + [pscustomobject]@{ name = $n; unblockAt = $null } } } | Out-Null
    $n
}
function Unblock-Site($site) {
    $n = Normalize $site
    Authed { param($s) $x = $s.sites | Where-Object { $_.name -eq $n }; if (-not $x) { throw "$n is not blocked" }; $x.unblockAt = (Now) + $s.delay }
    $n
}
function Cancel-Site($site) {
    $n = Normalize $site
    Edit { param($s) $s.sites | Where-Object { $_.name -eq $n } | ForEach-Object { $_.unblockAt = $null } } | Out-Null
    $n
}
function Set-Delay($text) {   # longer applies now; shorter only after the current delay has passed
    $v = Secs $text
    Edit { param($s) if ($v -ge $s.delay) { $s.delay = $v; $s.pendingDelay = $null } else { $s.pendingDelay = [pscustomobject]@{ value = $v; at = (Now) + $s.delay } } } | Out-Null
}
function Change-Pw { if ((Load).hash) { Authed { param($s) } }; New-Pw }
function Set-Recover($on) { Edit { param($s) $s.recoverAt = $(if ($on) { (Now) + 48 * 3600 }) } | Out-Null }
function Set-Uninstall($on) {
    if ($on) { Authed { param($s) $s.uninstallAt = (Now) + [math]::Max(48 * 3600, $s.delay) } }
    else { Edit { param($s) $s.uninstallAt = $null } | Out-Null }
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by test.ps1

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Run this from an administrator terminal.'
}

switch ($Cmd) {
    'install' {
        New-Item $Bin, $Dir -ItemType Directory -Force | Out-Null
        icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null   # SYSTEM + Administrators only
        foreach ($f in 'siteblock.ps1', 'siteblock-gui.ps1') { if ($PSScriptRoot -ne $Bin) { Copy-Item "$PSScriptRoot\$f" "$Bin\$f" -Force } }
        Set-Content "$Bin\siteblock.cmd" '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0siteblock.ps1" %*'
        $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Lnk)
        $l.TargetPath = 'powershell.exe'; $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Bin\siteblock-gui.ps1`""
        $l.IconLocation = "$env:SystemRoot\System32\imageres.dll,73"; $l.Save()
        $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if (($p -split ';') -notcontains $Bin) { [Environment]::SetEnvironmentVariable('Path', "$p;$Bin", 'Machine') }
        # Startup trigger + a 1-minute repeat: if the enforcer is killed, it is back within a minute.
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Bin\siteblock.ps1`" enforce"
        $t = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)))
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask $Task -Action $a -Trigger $t -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Stop-ScheduledTask $Task; Start-ScheduledTask $Task
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Bin\siteblock-gui.ps1`""
        'Installed. Open SiteBlock from the Start menu, or use "siteblock" in a NEW admin terminal.'
    }
    'enforce' {
        $last = $null
        while ($true) {
            try {
                $s = Lock {
                    $restore = $false
                    try { $s = Load } catch { if (-not $last) { throw }; $s = $last; $restore = $true }   # state corrupted -> restore
                    if (-not (Test-Path $State) -and $last) { $s = $last; $restore = $true }             # state deleted -> restore
                    $before = $s | ConvertTo-Json -Depth 5
                    $now = Now
                    $keep = @($s.sites | Where-Object { -not ($_.unblockAt -and $_.unblockAt -le $now) })
                    $s.sites = $keep
                    if ($s.pendingDelay -and $s.pendingDelay.at -le $now) { $s.delay = $s.pendingDelay.value; $s.pendingDelay = $null }
                    if ($s.recoverAt -and $s.recoverAt -le $now) { $s.hash = $null; $s.recoverAt = $null }
                    if ($restore -or ($s | ConvertTo-Json -Depth 5) -ne $before) { Save $s }
                    $s
                }
                $last = $s
                if ($s.uninstallAt -and $s.uninstallAt -le (Now)) { Remove-All; return }
                $names = @($s.sites | ForEach-Object { $_.name })
                Fix-Hosts @(HostNames $names)
                Fix-Policies $names
            } catch { Log $_ }
            Start-Sleep 2
        }
    }
    'add'     { "Blocked $(Add-Site $Arg -Whole:$WholeSite). Reload open tabs." }
    'unblock' { $n = Unblock-Site $Arg; "$n opens in $(Dur (Load).delay). 'siteblock cancel $n' keeps it blocked." }
    'cancel'  { "$(Cancel-Site $Arg) stays blocked." }
    'delay'   { Set-Delay $Arg; Status }
    'passwd'  { Change-Pw; 'Password changed.' }
    'recover' {
        if ($Arg -eq 'cancel') { Set-Recover $false; 'Password reset cancelled.' }
        else { Set-Recover $true; 'Password clears in 48h; then run siteblock passwd. Sites stay blocked meanwhile.' }
    }
    'uninstall' {
        if ($Arg -eq 'cancel') { Set-Uninstall $false; 'Uninstall cancelled.' }
        else { Set-Uninstall $true; Status }
    }
    'status' { Status }
    default { 'Usage: siteblock install | status | add <site> [-WholeSite] | unblock <site> | cancel <site> | delay 30m|2h | passwd | recover [cancel] | uninstall [cancel]' }
}
