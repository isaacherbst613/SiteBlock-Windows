. "$PSScriptRoot\siteblock.ps1"
function eq($got, $want) { if ($got -cne $want) { throw "expected [$want] got [$got]" } }

eq (Normalize 'https://www.YouTube.com/shorts/abc?x=1') 'youtube.com/shorts/abc'
eq (Normalize 'youtube.com/') 'youtube.com'
eq ((HostNames 'a.com', 'b.com/x') -join ',') 'a.com,www.a.com,m.a.com'
eq (Secs '2h') 7200

$orig = "127.0.0.1 localhost`r`n1.2.3.4 youtube.com # sneaky`r`n$Begin`r`n0.0.0.0 old.com`r`n$End`r`n"
$want = "127.0.0.1 localhost`r`n$Begin`r`n0.0.0.0 youtube.com`r`n:: youtube.com`r`n$End`r`n"
eq (BuildHosts $orig @('youtube.com')) $want
eq (BuildHosts $want @('youtube.com')) $want                          # idempotent
eq (BuildHosts $want @()) "127.0.0.1 localhost`r`n"                   # uninstall restores

$salt = [Convert]::ToBase64String((New-Object byte[] 16))
$s = [pscustomobject]@{ hash = (Hash 'pw' $salt); salt = $salt; fails = 0; lockUntil = 0 }
eq (Check-Pw $s 'pw') $null
1..5 | ForEach-Object { Check-Pw $s 'bad' } | Out-Null
if ((Check-Pw $s 'pw') -notlike 'Too many*') { throw 'lockout failed' }
'ok'
