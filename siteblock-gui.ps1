# SiteBlock window: same engine as siteblock.ps1, with password prompts as dialogs.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole('Administrators')) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    return
}
. "$PSScriptRoot\siteblock.ps1"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function New-Ctl($type, $props) { New-Object "Windows.Forms.$type" -Property $props }

# Replaces the console prompt used by Authed/New-Pw.
function ReadPw($prompt) {
    $f = New-Ctl Form @{ Text = 'SiteBlock'; ClientSize = '360,110'; FormBorderStyle = 'FixedDialog'; StartPosition = 'CenterParent'; MaximizeBox = $false; MinimizeBox = $false }
    $t = New-Ctl TextBox @{ Left = 12; Top = 44; Width = 336; UseSystemPasswordChar = $true }
    $ok = New-Ctl Button @{ Text = 'OK'; Left = 192; Top = 76; DialogResult = 'OK' }
    $no = New-Ctl Button @{ Text = 'Cancel'; Left = 273; Top = 76; DialogResult = 'Cancel' }
    $f.Controls.AddRange(@((New-Ctl Label @{ Text = $prompt; Left = 12; Top = 8; Width = 336; Height = 32 }), $t, $ok, $no))
    $f.AcceptButton = $ok; $f.CancelButton = $no
    if ($f.ShowDialog($form) -ne 'OK') { throw 'Cancelled.' }
    $t.Text
}

$form = New-Ctl Form @{ Text = 'SiteBlock'; ClientSize = '444,400'; FormBorderStyle = 'FixedSingle'; MaximizeBox = $false; StartPosition = 'CenterScreen' }
$site    = New-Ctl TextBox  @{ Left = 12; Top = 13; Width = 244 }
$whole   = New-Ctl CheckBox @{ Text = 'Whole site'; Left = 264; Top = 12; Width = 90 }
$add     = New-Ctl Button   @{ Text = 'Block'; Left = 357; Top = 11; Width = 75 }
$list    = New-Ctl ListView @{ Left = 12; Top = 44; Width = 420; Height = 220; View = 'Details'; FullRowSelect = $true; MultiSelect = $false; HideSelection = $false }
$unblock = New-Ctl Button   @{ Text = 'Unblock...'; Left = 12; Top = 272; Width = 100 }
$keep    = New-Ctl Button   @{ Text = 'Keep blocked'; Left = 12; Top = 272; Width = 100 }
$common  = New-Ctl Button   @{ Text = 'Block common sites...'; Left = 282; Top = 272; Width = 150 }
$delay   = New-Ctl TextBox  @{ Left = 12; Top = 312; Width = 100 }
$setDel  = New-Ctl Button   @{ Text = 'Set delay'; Left = 118; Top = 310; Width = 100 }
$pw      = New-Ctl Button   @{ Text = 'Change password...'; Left = 224; Top = 310; Width = 130 }
$forgot  = New-Ctl Button   @{ Text = 'Forgot...'; Left = 360; Top = 310; Width = 72 }
$note    = New-Ctl Label    @{ Left = 12; Top = 346; Width = 300; Height = 48 }
$uninst  = New-Ctl Button   @{ Text = 'Uninstall...'; Left = 332; Top = 364; Width = 100 }
[void]$list.Columns.Add('Site', 200); [void]$list.Columns.Add('Status', 196)
$form.Controls.AddRange(@($site, $whole, $add, $list, $unblock, $keep, $common,$delay, $setDel, $pw, $forgot, $note, $uninst))
$form.AcceptButton = $add
try { $site.PlaceholderText = 'youtube.com or a link'; $delay.PlaceholderText = '30m or 2h' } catch {}   # not on .NET Framework

# A selected site whose unblock is counting down (Tag = unblockAt) gets "Keep blocked" in place of "Unblock...".
function Update-Buttons { $pending = [bool]($list.SelectedItems.Count -and $list.SelectedItems[0].Tag); $keep.Visible = $pending; $unblock.Visible = -not $pending }
$list.Add_SelectedIndexChanged({ Update-Buttons })

function Refresh {
    $s = Load
    $sel = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Text }
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($x in $s.sites) { $i = $list.Items.Add($x.name); $i.Tag = $x.unblockAt; [void]$i.SubItems.Add((SiteStatus $x)); $i.Selected = $x.name -eq $sel }
    $list.EndUpdate()
    Update-Buttons
    $note.Text = (Summary) -join "`n"
    $uninst.Text = if ($s.uninstallAt) { 'Cancel uninstall' } else { 'Uninstall...' }
    $forgot.Text = if ($s.recoverAt) { 'Cancel reset' } else { 'Forgot...' }
}
function Try-Do([scriptblock]$b) {
    try { & $b } catch { if ("$_" -ne 'Cancelled.') { [void][Windows.Forms.MessageBox]::Show($form, "$_", 'SiteBlock') } }
    Refresh
}
function Selected { if (-not $list.SelectedItems.Count) { throw 'Select a site first.' }; $list.SelectedItems[0].Text }
function Confirm($msg) { [Windows.Forms.MessageBox]::Show($form, $msg, 'SiteBlock', 'OKCancel') -eq 'OK' }

# Preset for "Block common sites"; 1 = ticked by default. Unticked ones are often needed for work or school.
$Presets = [ordered]@{
    'facebook.com' = 1; 'messenger.com' = 1; 'instagram.com' = 1; 'threads.com' = 1; 'tiktok.com' = 1; 'x.com' = 1; 'twitter.com' = 1
    'snapchat.com' = 1; 'reddit.com' = 1; 'pinterest.com' = 1; 'tumblr.com' = 1
    'youtube.com' = 0; 'twitch.tv' = 0; 'discord.com' = 0; 'linkedin.com' = 0
}
function Pick-Common {
    $have = @((Load).sites | ForEach-Object { $_.name })
    $f = New-Ctl Form @{ Text = 'Block common sites'; ClientSize = '260,330'; FormBorderStyle = 'FixedDialog'; StartPosition = 'CenterParent'; MaximizeBox = $false; MinimizeBox = $false }
    $c = New-Ctl CheckedListBox @{ Left = 12; Top = 12; Width = 236; Height = 274; CheckOnClick = $true }
    foreach ($k in $Presets.Keys) { if ($have -notcontains $k) { [void]$c.Items.Add($k, [bool]$Presets[$k]) } }
    if (-not $c.Items.Count) { throw 'All of these are already blocked.' }
    $ok = New-Ctl Button @{ Text = 'Block'; Left = 92; Top = 296; DialogResult = 'OK' }
    $no = New-Ctl Button @{ Text = 'Cancel'; Left = 173; Top = 296; DialogResult = 'Cancel' }
    $f.Controls.AddRange(@($c, $ok, $no)); $f.AcceptButton = $ok; $f.CancelButton = $no
    if ($f.ShowDialog($form) -ne 'OK') { throw 'Cancelled.' }
    @($c.CheckedItems)
}
$common.Add_Click({ Try-Do { foreach ($n in Pick-Common) { [void](Add-Site $n) } } })

$add.Add_Click({ Try-Do { [void](Add-Site $site.Text -Whole:$whole.Checked); $site.Clear(); $whole.Checked = $false } })
$unblock.Add_Click({ Try-Do { [void](Unblock-Site (Selected)) } })
$keep.Add_Click({ Try-Do { [void](Cancel-Site (Selected)) } })
$setDel.Add_Click({ Try-Do { Set-Delay $delay.Text; $delay.Clear() } })
$pw.Add_Click({ Try-Do { Change-Pw } })
$forgot.Add_Click({ Try-Do {
    if ((Load).recoverAt) { Set-Recover $false }
    elseif (Confirm 'Clear the SiteBlock password in 48 hours? Sites stay blocked meanwhile; afterwards choose a new one with "Change password".') { Set-Recover $true }
} })
$uninst.Add_Click({ Try-Do {
    if ((Load).uninstallAt) { Set-Uninstall $false }
    elseif (Confirm 'Remove SiteBlock after a 48-hour wait (or your unblock delay, if longer)? Sites stay blocked until then.') { Set-Uninstall $true }
} })

$timer = New-Ctl Timer @{ Interval = 5000 }
$timer.Add_Tick({ try { Refresh } catch {} }); $timer.Start()   # a failed refresh just retries on the next tick
Refresh
[void]$form.ShowDialog()
