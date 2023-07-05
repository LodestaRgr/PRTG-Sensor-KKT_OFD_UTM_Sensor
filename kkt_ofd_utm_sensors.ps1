#сенсор 1 - Счетчик ответа от ОФД (Mikroitk to JSON)
#сенсор 2 - Опрос UTM и вывод данных на PRTG сенсор EXEXML
#setting:
#	- EXE/Script:	kkt_ofd_utm_sensors.ps1
#	- Parameters:	-gw_name GW-ROUTER -kkt_ip 192.168.10.205 -utm 1
#example:
#	powershell -NoProfile -ExecutionPolicy Bypass -File kkt_ofd_utm_sensors.ps1 -gw_name GW-TSALIKOVA -kkt_ip 192.168.10.205 -utm 1

param(
   [int]$ofd     = 1,			#УТМ 0 - выкл, 1 - включить
   [int]$utm     = 0,			#УТМ 0 - выкл, 1 - включить
   [int]$ofd_day = 7,			#дней до предупреждения о неперадачи данных в ОФД
[string]$gw_name = 'GW-TELMANA',	#имя роутера, например: GW-TELMANA
[string]$kkt_ip  = '192.168.0.205',	#ip адрес ККТ
[string]$utm_ip  = $kkt_ip,		#ip адрет УТМ
[string]$ofd_url = '',			#url адрес списка передачи данных ОФД (JSON Mikrotik)
[string]$utm_url = '',			#url адрес информации УТМ (:8080/api/gost/orginfo)
[string]$utm_fsrar_url = ''		#url адрес FSRAR_ID УТМ (:8080/diagnosis)
)

if (!$ofd_url) {$ofd_url='http://172.16.0.253:7770/OFD/' + $gw_name + '.html'}
if (!$utm_url) {$utm_url='http://' + $utm_ip + ':8080/api/gost/orginfo'}
if (!$utm_fsrar_url) {$utm_fsrar_url='http://' + $utm_ip + ':8080/diagnosis'}

$error_message = ''

#Write-Output $ofd_url
#Write-Output $utm_url

# Function to write back an XML error in the format PRTG expects
function Write-Xml-Error($ErrorMessage)
{
    $xmlstring  = "<?xml version=""1.0"" encoding=""CP866"" ?>`n"
    $xmlstring += "<prtg>`n"
    $xmlstring += "<error>1</error>`n"
    $xmlstring += "<text>" + $ErrorMessage + "</text>`n"
    $xmlstring += "</prtg>"

    Write-Output $xmlstring 
}

# Function to return the XML output in the format PRTG expects
function Write-Xml-Output($xml) 
{
    $xmlstring  = "<?xml version=""1.0"" encoding=""CP866"" ?>`n"
    $xmlstring += "<prtg>`n"
    $xmlString += $xml
    $xmlstring += "</prtg>"

    Write-Output $xmlstring
}

function Iterate-Tree($jsonTree) {
    $result = @()
    foreach ($node in $jsonTree) {
        $nodeObj = New-Object psobject
        foreach ($property in $node.Keys) {
            if ($node[$property] -is [System.Collections.Generic.Dictionary[String, Object]] -or $node[$property] -is [Object[]]) {
                $inner = @()
                $inner += Iterate-Tree $node[$property]
                $nodeObj  | Add-Member -MemberType NoteProperty -Name $property -Value $inner
            } else {
                $nodeObj  | Add-Member -MemberType NoteProperty -Name $property -Value $node[$property]
                #$nodeHash.Add($property, $node[$property])
            }
        }
        $result += $nodeObj
    }
    return $result
}

function ConvertFrom-Json20{ 
    [cmdletbinding()]
    Param (
        [parameter(ValueFromPipeline=$true)][object] $PS_Object
    )

    add-type -assembly system.web.extensions
    $PS_JavascriptSerializer=new-object system.web.script.serialization.javascriptSerializer
    $PS_DeserializeObject = ,$PS_JavascriptSerializer.DeserializeObject($PS_Object) 

    #Convert Dictionary to Objects
    $PS_DeserializeObject = Iterate-Tree $PS_DeserializeObject

    return $PS_DeserializeObject
}

$web_client = new-object system.net.webclient
$xml = ""

#-- ОФД

try 
{
        if ($ofd)
	{ 
	#-- считать последние переданные данные в ОФД

	$build_info	= $web_client.DownloadString($ofd_url)
	$build_info	= $build_info.split('[')[-1].split(']')[0]	# отрезать '{"result":[' и ']}''
	$jsonArray 	= ConvertFrom-Json20 $build_info
	$result 	= $jsonArray."ip_$kkt_ip"

	Write-Host      $result

	[int]$out_day = 0

	if (!$result) {
	    $out_day = $ofd_day
	}else{
#	--- week
	    if ($result.contains('w')){
	        $out_day+= [int]($result.split('w')[0])*7
		$result = $result.split('w')[1]
	    }
#	--- days
	    if ($result.contains('d')){
	        $out_day+= $result.split('d')[0]
		$result = $result.split('d')[1]
	    }
#	--- zero days
	    if ($out_day -eq 0){
	        $out_day = ($ofd_day-1)
	    }else{
		$out_day = ($ofd_day-1)-$out_day
	    }
	}
#	Write-Host      $out_day
#	$out_day		= "5"

	$xml+="
	<result>
	<channel>$kkt_ip - ОФД</channel>
	<value>$out_day</value>
	<CustomUnit>дней</CustomUnit>
	<LimitMaxError>" + ($ofd_day*0.95) + "</LimitMaxError>
	<LimitMaxWarning>" + ($ofd_day*0.7) + "</LimitMaxWarning>
	<LimitWarningMsg>ОФД долго не получает данные</LimitWarningMsg>
	<LimitErrorMsg>ОФД не получает данные !!!</LimitErrorMsg>
	<LimitMode>1</LimitMode>
	</result>`n"
	}
}
catch 
{
#	Write-Xml-Error ("Exception occured (line #" + $_.InvocationInfo.ScriptLineNumber + ", Char#" + $_.InvocationInfo.OffsetInLine + "): " + $_.Exception.Message)
	if(!$error_message){$error_message = "Нет связи с сервером " + $gw_name + " !"}
}

#-- УТМ

try
{

	if ($utm)
	{
	#-- считать FSRAR_ID ЕГАИС с UTM

	$build_info	= $web_client.DownloadString($utm_fsrar_url)

	if($build_info -match '<CN>(?<Name>.+)</CN>'){
		$FSRAR_ID = $Matches.Name
	}

#	Write-Host      $FSRAR_ID

	#-- считать дату окончания сертификата ЕГАИС с UTM

	$build_info	= $web_client.DownloadString($utm_url)
	$jsonArray	= ConvertFrom-Json20 $build_info

#	Фамилия ---
	$GOSTsurname	= $jsonArray."surname"
#	UTF8 -> Win-1252
	$GOSTsurname	= [System.Text.Encoding]::Default.GetBytes($GOSTsurname)
	$GOSTsurname	= [System.Text.Encoding]::UTF8.GetString($GOSTsurname)

#	Имя Отчество ---
	$GOSTgivenname	= $jsonArray."givenname"
#	UTF8 -> Win-1252
	$GOSTgivenname	= [System.Text.Encoding]::Default.GetBytes($GOSTgivenname)
	$GOSTgivenname	= [System.Text.Encoding]::UTF8.GetString($GOSTgivenname)


#	дата окончания сертификата
	$result 	= $jsonArray."to"

#	Write-Host      $result

	$GOSTdate = [DateTime]::ParseExact($result.split(' ')[0], 'dd.MM.yyyy', $null)
	$GOSTdays = ($GOSTdate-(Get-Date).Date).Days

#	$GOSTdays = 2

	$xml+="
	<result>
	<channel>$utm_ip - УТМ ГОСТ</channel>
	<value>$GOSTdays</value>
	<CustomUnit>дней</CustomUnit>
	<LimitMinError>3</LimitMinError>
	<LimitMinWarning>14</LimitMinWarning>
	<LimitWarningMsg>ГОСТ сертификат закончится через $GOSTdays дней.</LimitWarningMsg>
	<LimitErrorMsg>ГОСТ сертификат ИСТЕКАЕТ " + $GOSTdate.ToString("dd.MM.yyyy") + " !!!</LimitErrorMsg>
	<LimitMode>1</LimitMode>
	</result>`n"
#
	$xml+="
	<text>ФСРАР ID: $FSRAR_ID / ГОСТ до: " + $GOSTdate.ToString("dd.MM.yyyy") + " ($GOSTdays дней) ($GOSTsurname $GOSTgivenname)</text>`n"
	}

}
catch 
{
#	Write-Xml-Error ("Exception occured (line #" + $_.InvocationInfo.ScriptLineNumber + ", Char#" + $_.InvocationInfo.OffsetInLine + "): " + $_.Exception.Message)
	if(!$error_message){$error_message= "Нет связи с УТМ (" + $utm_ip + ") !"}
}

if($error_message){
	Write-Xml-Error ($error_message)
}else{
#[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
	#-- Вывод данных на экран
	Write-Xml-Output ($xml) -encoding utf8
}