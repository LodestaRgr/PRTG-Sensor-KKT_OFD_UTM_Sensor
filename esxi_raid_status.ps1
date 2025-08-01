#-- PRTG Custom Sensor - Мониторинг состояния RAID массивов на ESXi через StorCLI по SSH
#
#      Скрипт подключается по SSH к ESXi-хосту, выполняет команду `storcli /c0 /vall show`,
#      анализирует статус каждого RAID массива (VD), и возвращает XML в формате EXEXML для PRTG
#
#      Работает как EXE/Script Advanced Sensor в PRTG. Каждый RAID массив отображается как отдельный канал.
#      В случае если хотя бы один из массивов не находится в состоянии Optimal, скрипт помечает соответствующий канал (через <Limit...>)
#      и выводит текст с указанием проблемных массивов.
#
#      Инструкция добавления сенсора:
#       - Перейди в Devices -> выбери конкретное устройство (например, esxi01, nas1, или другое с IP).
#       - Открой его.
#       - В меню "Sensors" нажми Add Sensor.
#       - Выберите "EXE/Script Advanced"
#       - EXE/Script выберите "esxi_raid_status.ps1"
#       - Environment - включите Set placeholders as environment values
#       - Paramiters укажите (через пробел) если необходимо: -esxiHost <ESXi_IP> (и/или) -sshpwd <Пароль>

# - Установленные в той же папке утилиты:
#   - plink.exe (из пакета PuTTY)
#   - pscp.exe  (из пакета PuTTY)
#   - psexec.exe (из SysInternals Suite)
#
# - Приватный SSH-ключ в формате PuTTY: esxi.ppk
#   - На стороне ESXi:
#
#     - Публичный ключ должен быть добавлен в файл:
#
#       vi /etc/ssh/keys-root/authorized_keys
#
#     - Установить права:
#
#       chmod 700 /etc/ssh/keys-root
#       chmod 600 /etc/ssh/keys-root/authorized_keys
#
# - Подтвердите SSH fingerprint вручную перед использованием:
#   - Запустите от имени SYSTEM:
#
#       start psexec -i -s cmd.exe /k cd "C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML"
#
#   - Подтвердите fingerprint:
#
#       plink.exe -i esxi.ppk root@<ESXi_IP>
#
# - Параметры для PRTG:
#
#   [-esxiHost <ESXi_IP>] - необязательный, если не указывает берет IP адрес устройства prtg_host
#			    !!! Обязательный параметер для включения - Environment -> Set placeholders as environment values
#   [-sshpwd <Пароль root>] - необязательный, если используется ключ

param(
    [string]$esxiHost,
    [string]$sshpwd
)

# Если параметр $esxiHost не указан - пытаемся взять из переменной окружения
if (-not $esxiHost -or $esxiHost -eq "") {
    if ($env:prtg_host -and $env:prtg_host -ne "") {
        $esxiHost = $env:prtg_host
    } else {
        $errorXml = @"
<?xml version="1.0" encoding="CP866"?>
<prtg>
  <error>1</error>
  <text>Не указан адрес ESXi</text>
</prtg>
"@
        Write-Output $errorXml
        exit 1
    }
}

# Константы
$username = "root"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$plink = Join-Path $scriptDir "plink.exe"
$pscp = Join-Path $scriptDir "pscp.exe"
$privateKey = Join-Path $scriptDir "esxi.ppk"

$remoteFile = "/tmp/storcli_output.txt"
$localFile = Join-Path $scriptDir "storcli_output.txt"

# Выполнить storcli на ESXi и записать в файл
$remoteCommand = "storcli /c0 /vall show > $remoteFile"

if ($sshpwd) {
& $plink -ssh -batch -pw $sshpwd -i $privateKey "$username`@$esxiHost" $remoteCommand | Out-Null
& $pscp -batch -pw $sshpwd -i $privateKey "$username`@$esxiHost`:$remoteFile" "$localFile" | Out-Null
} else {
& $plink -ssh -batch -i $privateKey "$username`@$esxiHost" $remoteCommand | Out-Null
& $pscp -batch -i $privateKey "$username`@$esxiHost`:$remoteFile" "$localFile" | Out-Null
}

# Проверка существования
if (-Not (Test-Path $localFile)) {
    $errorXml = @"
<?xml version="1.0" encoding="CP866"?>
<prtg>
  <error>1</error>
  <text>Не загружаются данные с ESXi</text>
</prtg>
"@
    Write-Output $errorXml
    exit 1
}

# Чтение строк
$allLines = Get-Content -Path $localFile -Encoding UTF8
$raidLines = $allLines | Where-Object { $_ -match '^\d+/\d+\s+RAID\d+' }

$results = @()
$problems = @()

foreach ($line in $raidLines) {
    $columns = ($line -split '\s{2,}|\t+| +') -ne ""
    $vdid  = $columns[0]  # 0/0, 1/1 и т.п.
    $level = $columns[1]  # RAID5, RAID1 и т.п.
    $state = $columns[2]  # Optl, Dgrd и т.п.
    $name  = $columns[-1] # Имя VD (последнее значение)

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
    <LimitErrorMsg>RAID в восстановлении или деградации</LimitErrorMsg>
    <LimitMode>1</LimitMode>
  </result>
"@
}

# Общий текст
if ($problems.Count -eq 0) {
    $summary = "OK"
} else {
    $summary = "WARNING: " + ($problems -join ", ")
}

# Формируем итоговый XML
$xml = @()
$xml += '<?xml version="1.0" encoding="CP866"?>'
$xml += '<prtg>'
$xml += $results
$xml += "  <text>$summary</text>"

# Добавляем <error>1</error> если есть хотя бы один сбой
if ($problems.Count -gt 0) {
    $xml += "  <error>1</error>"
}

$xml += '</prtg>'

Write-Output ($xml -join "`n")

# Очистка
Remove-Item $localFile -Force -ErrorAction SilentlyContinue