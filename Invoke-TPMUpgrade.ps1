<#
.SYNOPSIS
    Invoke TPM Firmware Update process.

.DESCRIPTION
    This script will invoke a TPM update process for a viarity of manufactures from TPM 1.2 -> TPM 2.0 if necessary. This process can be ran in WINPE.

.PARAMETER LogFileName
    Set the name of the log file produced by the flash utility.

.EXAMPLE
    

.NOTES
    FileName:    Invoke-TPMUpgrade.ps1
    Author:      Richard tracy
    Contact:     richard.j.tracy@gmail.com
    Created:     2018-08-24
    Inspired:    Anton Romanyuk
    
    Version history:
    1.1.0 - (2018-11-07) Script created
#>
##*===========================================================================
##* FUNCTIONS
##*===========================================================================
Function Write-LogEntry {
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,
        [Parameter(Mandatory=$false,Position=2)]
		[string]$Source = '',
        [parameter(Mandatory=$false)]
        [ValidateSet(0,1,2,3,4)]
        [int16]$Severity,

        [parameter(Mandatory=$false, HelpMessage="Name of the log file that the entry will written to.")]
        [ValidateNotNullOrEmpty()]
        [string]$OutputLogFile = $Global:LogFilePath,

        [parameter(Mandatory=$false)]
        [switch]$Outhost
    )
    ## Get the name of this function
    [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

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
    $LogFormat = "<![LOG[$Message]LOG]!>" + "<time=`"$LogTimePlusBias`" " + "date=`"$LogDate`" " + "component=`"$ScriptSource`" " + "context=`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " + "type=`"$Severity`" " + "thread=`"$PID`" " + "file=`"$ScriptSource`">"
    
    # Add value to log file
    try {
        Out-File -InputObject $LogFormat -Append -NoClobber -Encoding Default -FilePath $OutputLogFile -ErrorAction Stop
    }
    catch {
        Write-Host ("[{0}] [{1}] :: Unable to append log entry to [{1}], error: {2}" -f $LogTimePlusBias,$ScriptSource,$OutputLogFile,$_.Exception.ErrorMessage) -ForegroundColor Red
    }
    If($Outhost){
        If($Source){
            $OutputMsg = ("[{0}] [{1}] :: {2}" -f $LogTimePlusBias,$Source,$Message)
        }
        Else{
            $OutputMsg = ("[{0}] [{1}] :: {2}" -f $LogTimePlusBias,$ScriptSource,$Message)
        }

        Switch($Severity){
            0       {Write-Host $OutputMsg -ForegroundColor Green}
            1       {Write-Host $OutputMsg -ForegroundColor Gray}
            2       {Write-Warning $OutputMsg}
            3       {Write-Host $OutputMsg -ForegroundColor Red}
            4       {If($Global:Verbose){Write-Verbose $OutputMsg}}
            default {Write-Host $OutputMsg}
        }
    }
}


# Start Main Code Here
# https://stackoverflow.com/questions/8761888/capturing-standard-out-and-error-with-start-process
Function Execute-Command{
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [parameter(Mandatory=$false)]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [string]$Arguments

    )

    If(Test-Path $Path){
        Try{
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $Path
            $pinfo.RedirectStandardError = $true
            $pinfo.RedirectStandardOutput = $true
            $pinfo.UseShellExecute = $false
            $pinfo.Arguments = $Arguments
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $pinfo
            $p.Start() | Out-Null
            $p.WaitForExit()
            [pscustomobject]@{
                commandTitle = $Title
                stdout = $p.StandardOutput.ReadToEnd()
                stderr = $p.StandardError.ReadToEnd()
                ExitCode = $p.ExitCode  
            }
        }
        Catch{
            Write-LogEntry ("Failed to execute command [{0} {1}]. Exit Code: {2}" -f $Path,$Arguments,$p.ExitCode) -Severity 3 -Outhost
        }
    }
    Else{
        Write-LogEntry ("Unable to execute command [{0} {1}]. Path not found" -f $Path,$Arguments) -Severity 2 -Outhost
    }
}

##*===========================================================================
##* VARIABLES
##*===========================================================================
## Instead fo using $PSScriptRoot variable, use the custom InvocationInfo for ISE runs
If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
[string]$scriptDirectory = Split-Path $MyInvocation.MyCommand.Path -Parent
[string]$scriptName = Split-Path $MyInvocation.MyCommand.Path -Leaf
[string]$scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptName)
[int]$OSBuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
[string]$Make = (Get-WmiObject -Class Win32_ComputerSystem).Manufacturer


#Create Paths
$TPMFirmwarePath = Join-Path $scriptDirectory -ChildPath TPMFirmware
$TempPath = Join-Path $scriptDirectory -ChildPath Temp
$ToolsPath = Join-Path $scriptDirectory -ChildPath Tools


Try
{
	$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
    $Progress = New-Object -ComObject Microsoft.SMS.TSprogressUI
	#$logPath = $tsenv.Value("LogPath")
    $LogPath = $tsenv.Value("_SMSTSLogPath")
    $tsenv.Value("SMSTS_TPMUpdate") = "False"
    $Make = $TSenv.Value("Make")
}
Catch
{
	Write-Warning "TS environment not detected. Assuming stand-alone mode."
}

If(!$LogPath){$LogPath = $env:TEMP}
[string]$FileName = $scriptBaseName +'.log'
$Global:LogFilePath = Join-Path $LogPath -ChildPath $FileName
Write-Host "Using log file: $LogFilePath"


#Preset Reboot to NO
$NeedReboot = "NO"

##*===========================================================================
##* MAIN
##*===========================================================================
Write-LogEntry "Logging to $LogFilePath" -Outhost

#Get TB Password from File
$BiosPassword = Get-Content .\BIOSPassword.txt -ErrorAction SilentlyContinue
$PasswordBin = Get-ChildItem $scriptDirectory -Filter password.bin -ErrorAction SilentlyContinue

if ($tsenv -and $inPE) {
    Write-LogEntry "TaskSequence is running in Windows Preinstallation Environment (PE)" -Outhost
}
Else{
    Write-LogEntry "TaskSequence is running in Windows Environment" -Outhost

    # Detect Bitlocker Status
	$OSVolumeEncypted = if ((Manage-Bde -Status C:) -match "Protection On") { Write-Output $true } else { Write-Output $false }
		
	# Supend Bitlocker if $OSVolumeEncypted is $true
	if ($OSVolumeEncypted -eq $true) {
		Write-LogEntry "Suspending BitLocker protected volume: C:" -Outhost
		Manage-Bde -Protectors -Disable C:
	}
                
}


Switch ($Make){
"HP"{
    Write-LogEntry "Detecting whether a platform supports HP discrete TPM mode switching in real time." -Outhost
    Write-LogEntry "For HP platforms that support TPM mode changes, the output from powershell should include: ManufacturerVersion: 6.40, 6.41 or 6.43 (1.2 mode), or 7.40, 7.41, 7.60, 7.61 or 7.63 (2.0 mode)"
	Write-LogEntryt " Checking if installed TPM firmware is affected by ADV170012. Vulnerable TPM versions: ManufacturerVersion: 6.40 or 6.41 (1.2 mode), or 7.40, 7.41, 7.60 or 7.61 (2.0 mode)"
    $tpm_mode = (Get-TPM).ManufacturerVersion
    Write-LogEntry "Following ManufacturerVersion detected: $tpm_mode"

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
        Write-LogEntry "Changing TPM Mode 1.2->2.0." -Outhost
	    Write-LogEntry "Pause the TPM auto-own behavior temporarily."
        Disable-TpmAutoProvisioning -OnlyForNextRestart

        
        #Set Command Arguments for TPM Update
        If($PasswordBin){   
            $cmdLine  = ' -f"' + $BinFile.FullName + '" -p"' + $PasswordBin.FullName + '" -s'
        }
        else {
            $cmdLine  = ' -f"' + $BinFile.FullName + '" -s'
        }

        Write-LogEntry ("Changing TPM Mode using [{0}\TPMConfig64.exe]..." -f $ToolsPath) -Outhost
	    $result = Execute-Command -Title "Change TPM Mode" -Path $ToolsPath\TPMConfig64.exe -Arguments $cmdLine

        $NeedReboot = "YES"
	    Write-Host $result
    }
}
"Dell Inc."{
    
    Write-LogEntry "Detecting whether a platform supports Dell discrete TPM mode switching in real time." -Outhost
    Write-LogEntry "For Dell platforms that support TPM mode changes, the output from powershell should include: ManufacturerVersion: 5.81 (1.2 mode), or 1.3 (2.0 mode)"
    $tpm_mode = (Get-TPM).ManufacturerVersion
    Write-LogEntry "Following ManufacturerVersion detected: $tpm_mode"

    switch($tpm_mode){
        "5.81" {$ExeFile = Get-ChildItem $TPMFirmwarePath -Filter DellTpm2.0_Fw1.3* -Recurse | Select -First 1}
        "1.3"  {$ExeFile = Get-ChildItem $TPMFirmwarePath -Filter DellTpm1.2_Fw5.8* -Recurse | Select -First 1}
        default {$ExeFile = $null}
    }

    If ($ExeFile -ne $null) {
        Write-LogEntry "Changing TPM Mode 1.2->2.0." -Outhost
	    Write-LogEntry "Pause the TPM auto-own behavior temporarily."
        Disable-TpmAutoProvisioning -OnlyForNextRestart

        #Set Command Arguments for TPM Update
        If($BiosPassword){   
            $cmdLine  = ' /s /p="' + $BiosPassword + '" /l="' + $LogPath + '\' + $ExeFile.BaseName + '.log"'
        }
        else {
            $cmdLine  = ' /s /l="' + $LogPath + '\' + $ExeFile.BaseName + '.log"'
        }

        Write-LogEntry ("Changing TPM Mode using [{0}]..." -f $ExeFile.FullName) -Outhost
	    $result = Execute-Command -Title "Change TPM Mode" -Path $ExeFile.FullName -Arguments $cmdLine

        $NeedReboot = "YES"
	    Write-Host $result
    }
    Else{
        Write-LogEntry ("TPM mode ({0}), upgrade file was not found or needed, exiting.." -f $tpm_mode) -Outhost
        Exit 0
    }
}
Default {
        Write-LogEntry "$Make is not supported, exiting..." -Outhost
        Exit 0
    }
}

# Execute reboot if needed
If ($NeedReboot -eq "YES") {
    Write-LogEntry "A reboot is required. The installation will resume after restart." -Outhost
    $TSenv.Value("SMSTS_TPMRebootRequired") = $NeedReboot
	Exit 0
}