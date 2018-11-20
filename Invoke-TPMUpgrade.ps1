<#
.Synopsis
    TPM 1.2 -> TPM 2.0 Updater
.DESCRIPTION
    Verifies TPM mode and initiates TPM 1.2 -> TPM 2.0 discrete upgrade if necessary
.EXAMPLE
    VerifyTpmMode.ps1
.NOTES
    Created:	 2017-09-19
	Updated:	 2017-11-08
    Version:	 1.2
    Author - Anton Romanyuk
    Twitter: @admiraltolwyn
    Blog   : http://www.vacuumbreather.com
    Disclaimer:
    This script is provided 'AS IS' with no warranties, confers no rights and 
    is not supported by the author.
.LINK
    http://www.vacuumbreather.com
.NOTES
	1.1: Added support for detection and remediation of vulnerable TPM firmware on HP models
	1.2: Fixed inconsistencies in the logging messages
#>
##*===========================================================================
##* FUNCTIONS
##*===========================================================================
function Write-LogEntry {
    param(
        [parameter(Mandatory=$true, HelpMessage="Value added to the log file.")]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [parameter(Mandatory=$false)]
        [ValidateSet(0,1,2,3)]
        [int16]$Severity,

        [parameter(Mandatory=$false, HelpMessage="Name of the log file that the entry will written to.")]
        [ValidateNotNullOrEmpty()]
        [string]$fileArgName = $LogFilePath,

        [parameter(Mandatory=$false)]
        [switch]$Outhost
    )
    
    [string]$LogTime = (Get-Date -Format 'HH:mm:ss.fff').ToString()
	[string]$LogDate = (Get-Date -Format 'MM-dd-yyyy').ToString()
	[int32]$script:LogTimeZoneBias = [timezone]::CurrentTimeZone.GetUtcOffset([datetime]::Now).TotalMinutes
	[string]$LogTimePlusBias = $LogTime + $script:LogTimeZoneBias
    #  Get the file name of the source script

    Try {
	    If ($script:MyInvocation.Value.ScriptName) {
		    [string]$ScriptSource = Split-Path -Path $script:MyInvocation.Value.ScriptName -Leaf -ErrorAction 'Stop'
	    }
	    Else {
		    [string]$ScriptSource = Split-Path -Path $script:MyInvocation.MyCommand.Definition -Leaf -ErrorAction 'Stop'
	    }
    }
    Catch {
	    $ScriptSource = ''
    }
    
    
    If(!$Severity){$Severity = 1}
    $LogFormat = "<![LOG[$Value]LOG]!>" + "<time=`"$LogTimePlusBias`" " + "date=`"$LogDate`" " + "component=`"$ScriptSource`" " + "context=`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " + "type=`"$Severity`" " + "thread=`"$PID`" " + "file=`"$ScriptSource`">"
    
    # Add value to log file
    try {
        Out-File -InputObject $LogFormat -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-LogEntry -Message "Unable to append log entry to $LogFilePath file"
    }
    If($Outhost){
        Switch($Severity){
            0       {Write-Host $Value -ForegroundColor Gray}
            1       {Write-Host $Value}
            2       {Write-Warning $Value}
            3       {Write-Host $Value -ForegroundColor Red}
            default {Write-Host $Value}
        }
    }
}

# Start Main Code Here
# https://stackoverflow.com/questions/8761888/capturing-standard-out-and-error-with-start-process
Function Execute-Command ($commandTitle, $commandPath, $commandArguments)
{
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $commandPath
    $pinfo.RedirectStandardError = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.UseShellExecute = $false
    $pinfo.Arguments = $commandArguments
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    $p.WaitForExit()
    [pscustomobject]@{
        commandTitle = $commandTitle
        stdout = $p.StandardOutput.ReadToEnd()
        stderr = $p.StandardError.ReadToEnd()
        ExitCode = $p.ExitCode  
    }
}

##*===========================================================================
##* VARIABLES
##*===========================================================================
## Instead fo using $PSScriptRoot variable, use the custom InvocationInfo for ISE runs
If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
[string]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent
[string]$scriptPath = $InvocationInfo.MyCommand.Definition
[string]$scriptName = [IO.Path]::GetFileNameWithoutExtension($scriptPath)

#Create Paths
$TPMFirmwarePath = Join-Path $scriptDirectory -ChildPath TPMFirmware
$TempPath = Join-Path $scriptDirectory -ChildPath Temp
$ToolsPath = Join-Path $scriptDirectory -ChildPath Tools

Try
{
	$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
	$LogPath = $tsenv.Value("LogPath")
    #$LogPath = $tsenv.Value("_SMSTSLogPath")
    $Make = $TSenv.Value("Make")
    $inPE = $tsenv.Value("_SMSTSInWinPE")
    $tsenv.Value("SMSTS_TPMUpdate") = "False"
}
Catch
{
	Write-Warning "TS environment not detected. Assuming stand-alone mode."
	$LogPath = $env:TEMP
}

[string]$fileArgName = $scriptName +'.log'
$LogFilePath = Join-Path -Path $LogPath -ChildPath $fileArgName


$NeedReboot = "NO"

##*===========================================================================
##* MAIN
##*===========================================================================
# Start the logging 
Start-Transcript $LogFilePath
Write-Host "$($myInvocation.MyCommand) - Logging to $LogFilePath"

#Get TB Password from File
$BiosPassword = Get-Content .\BIOSPassword.txt -ErrorAction SilentlyContinue
$PasswordBin = Get-ChildItem $scriptDirectory -Filter password.bin -ErrorAction SilentlyContinue

Switch ($Make){
"HP"{
    Write-Host "$($myInvocation.MyCommand) - Detecting whether a platform supports HP discrete TPM mode switching in real time."
    Write-Host "$($myInvocation.MyCommand) - For HP platforms that support TPM mode changes, the output from powershell should include: ManufacturerVersion: 6.40, 6.41 or 6.43 (1.2 mode), or 7.40, 7.41, 7.60, 7.61 or 7.63 (2.0 mode)"
	Write-Host "$($myInvocation.MyCommand) - Checking if installed TPM firmware is affected by ADV170012. Vulnerable TPM versions: ManufacturerVersion: 6.40 or 6.41 (1.2 mode), or 7.40, 7.41, 7.60 or 7.61 (2.0 mode)"
    $tpm_mode = (Get-TPM).ManufacturerVersion
    Write-Host "$($myInvocation.MyCommand) - Following ManufacturerVersion detected: $tpm_mode"

    switch($tpm_mode){
        "6.40" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_6.40.190.0_to_TPM20* -Recurse | Select -First 1}
        "6.41" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_6.41.190.0_to_TPM20* -Recurse | Select -First 1}
        "6.43" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_6.43.190.0_to_TPM20* -Recurse | Select -First 1}
        "7.40" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_7.40.190.0_to_TPM20* -Recurse | Select -First 1}
        "7.41" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_7.41.190.0_to_TPM20* -Recurse | Select -First 1}
        "7.60" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_7.60.190.0_to_TPM20* -Recurse | Select -First 1}
        "7.61" {$BinFile = Get-ChildItem $TPMFirmwarePath -Filter TPM12_7.61.190.0_to_TPM20* -Recurse | Select -First 1}
        default {$BinFile = $null}
    }

    If ($BinFile) {
		Write-Host "$($myInvocation.MyCommand) - This Infineon firmware version is not safe."
        Write-Host "$($myInvocation.MyCommand) - Changing TPM Mode 1.2->2.0."
	    Write-Host "$($myInvocation.MyCommand) - Pause the TPM auto-own behavior temporarily."
        Disable-TpmAutoProvisioning -OnlyForNextRestart

        
        #Set Command Arguments for TPM Update
        If($PasswordBin){   
            $cmdLine  = ' -f"' + $BinFile.FullName + '" -p"' + $PasswordBin.FullName + '" -s'
        }
        else {
            $cmdLine  = ' -f"' + $BinFile.FullName + '" -s'
        }

        Write-Host "$($myInvocation.MyCommand) - Changing TPM Mode..."
	    $log_tmp = Execute-Command -commandTitle "Change TPM Mode" -commandPath  $ToolsPath\TPMConfig64.exe -commandArguments $cmdLine

        $NeedReboot = "YES"
	    Write-Host $log_tmp
    }
}
"Dell Inc."{
    
    Write-Host "$($myInvocation.MyCommand) - Detecting whether a platform supports Dell discrete TPM mode switching in real time."
    Write-Host "$($myInvocation.MyCommand) - For Dell platforms that support TPM mode changes, the output from powershell should include: ManufacturerVersion: 5.81 (1.2 mode), or 1.3 (2.0 mode)"
    $tpm_mode = (Get-TPM).ManufacturerVersion
    Write-Host "$($myInvocation.MyCommand) - Following ManufacturerVersion detected: $tpm_mode"

    switch($tpm_mode){
        "5.81" {$ExeFile = Get-ChildItem $TPMFirmwarePath -Filter DellTpm2.0_Fw1.3* -Recurse | Select -First 1}
        "1.3"  {$ExeFile = Get-ChildItem $TPMFirmwarePath -Filter DellTpm1.2_Fw5.8* -Recurse | Select -First 1}
        default {$ExeFile = $null}
    }

    If ($ExeFile -eq $null) {
        Write-Host "$($myInvocation.MyCommand) - Changing TPM Mode 1.2->2.0."
	    Write-Host "$($myInvocation.MyCommand) - Pause the TPM auto-own behavior temporarily."
        Disable-TpmAutoProvisioning -OnlyForNextRestart

        #Set Command Arguments for TPM Update
        If($BiosPassword){   
            $cmdLine  = ' /s /p="' + $BiosPassword + '" /l="' + $LogPath + '\' + $ExeFile.BaseName + '.log"'
        }
        else {
            $cmdLine  = ' /s /l="' + $LogPath + '\' + $ExeFile.BaseName + '.log"'
        }

        Write-Host "$($myInvocation.MyCommand) - Changing TPM Mode..."
	    $log_tmp = Execute-Command -commandTitle "Change TPM Mode" -commandPath $ExeFile.FullName -commandArguments $cmdLine

        $NeedReboot = "YES"
	    Write-Host $log_tmp
    }
}
Default {
        Write-Host "$($myInvocation.MyCommand) - $Make is unsupported, exit" 
        Exit 0
    }
}

# Execute reboot if needed
If ($NeedReboot -eq "YES") {
    Write-Host "$($myInvocation.MyCommand) - A reboot is required. The installation will resume after restart."
    $TSenv.Value("NeedRebootTpmSwitch") = $NeedReboot
	Exit 0
}

# Stop logging 
Stop-Transcript