#-- PRTG Custom Sensor - ���������� ��������� RAID �������� �� ESXi ����� StorCLI �� SSH
#
#      ������ ������������ �� SSH � ESXi-�����, ��������� ������� `storcli /c0 /vall show`,
#      ����������� ������ ������� RAID ������� (VD), � ���������� XML � ������� EXEXML ��� PRTG
#
#      �������� ��� EXE/Script Advanced Sensor � PRTG. ������ RAID ������ ������������ ��� ��������� �����.
#      � ������ ���� ���� �� ���� �� �������� �� ��������� � ��������� Optimal, ������ �������� ��������������� ����� (����� <Limit...>)
#      � ������� ����� � ��������� ���������� ��������.
#
# - ������������� � ��� �� ����� �������:
#   - plink.exe (�� ������ PuTTY)
#   - pscp.exe  (�� ������ PuTTY)
#   - psexec.exe (�� SysInternals Suite)
#
# - ��������� SSH-���� � ������� PuTTY: esxi.ppk
#   - �� ������� ESXi:
#
#     - ��������� ���� ������ ���� �������� � ����:
#
#       vi /etc/ssh/keys-root/authorized_keys
#
#     - ���������� �����:
#
#       chmod 700 /etc/ssh/keys-root
#       chmod 600 /etc/ssh/keys-root/authorized_keys
#
# - ����������� SSH fingerprint ������� ����� ��������������:
#   - ��������� �� ����� SYSTEM:
#
#       start psexec -i -s cmd.exe
#
#   - ��������� � ����� �� ��������:
#
#       cd "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML"
#
#   - ����������� fingerprint:
#
#       plink.exe -i esxi.ppk root@<ESXi_IP>
#
# - ��������� ��� PRTG:
#
#   -esxiHost <ESXi_IP>

param(
    [string]$esxiHost
)

# ���������
$username = "root"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$plink = Join-Path $scriptDir "plink.exe"
$pscp = Join-Path $scriptDir "pscp.exe"
$privateKey = Join-Path $scriptDir "esxi.ppk"

$remoteFile = "/tmp/storcli_output.txt"
$localFile = Join-Path $scriptDir "storcli_output.txt"

# ��������� storcli �� ESXi � �������� � ����
$remoteCommand = "storcli /c0 /vall show > $remoteFile"
& $plink -ssh -batch -i $privateKey "$username`@$esxiHost" $remoteCommand | Out-Null
& $pscp -batch -i $privateKey "$username`@$esxiHost`:$remoteFile" "$localFile" | Out-Null

# �������� �������������
if (-Not (Test-Path $localFile)) {
    $errorXml = @"
<?xml version="1.0" encoding="CP866"?>
<prtg>
  <error>1</error>
  <text>�� ����������� ������ � ESXi</text>
</prtg>
"@
    Write-Output $errorXml
    exit 1
}

# ������ �����
$allLines = Get-Content -Path $localFile -Encoding UTF8
$raidLines = $allLines | Where-Object { $_ -match '^\d+/\d+\s+RAID\d+' }

$results = @()
$problems = @()

foreach ($line in $raidLines) {
    $columns = ($line -split '\s{2,}|\t+| +') -ne ""
    $vdid  = $columns[0]  # 0/0, 1/1 � �.�.
    $level = $columns[1]  # RAID5, RAID1 � �.�.
    $state = $columns[2]  # Optl, Dgrd � �.�.
    $name  = $columns[-1] # ��� VD (��������� ��������)

    $value = 2
    if ($state -match "Dgrd|Rbld|Offln") {
        $value = 1
        $problems += "$vdid $level - $name`: $state"
    } elseif ($state -eq "Optl") {
        $value = 0
    } else {
        $problems += "$vdid $level - $name`: $state"
    }

    $results += @"
  <result>
    <channel>$vdid $level - $name</channel>
    <value>$value</value>
    <LimitMaxError>1</LimitMaxError>
    <LimitErrorMsg>RAID � �������������� ��� ����������</LimitErrorMsg>
    <LimitMode>1</LimitMode>
  </result>
"@
}

# ����� �����
if ($problems.Count -eq 0) {
    $summary = "OK"
} else {
    $summary = "WARNING: " + ($problems -join ", ")
}

# ��������� �������� XML
$xml = @()
$xml += '<?xml version="1.0" encoding="CP866"?>'
$xml += '<prtg>'
$xml += $results
$xml += "  <text>$summary</text>"

# ��������� <error>1</error> ���� ���� ���� �� ���� ����
if ($problems.Count -gt 0) {
    $xml += "  <error>1</error>"
}

$xml += '</prtg>'

Write-Output ($xml -join "`n")

# �������
Remove-Item $localFile -Force -ErrorAction SilentlyContinue