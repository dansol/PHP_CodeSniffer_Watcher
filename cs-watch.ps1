<#
.SYNOPSIS
    This script monitors a specified folder for file changes and automatically runs the 
    `phpcbf` (PHP Code Beautifier and Fixer) command on modified PHP files. It supports 
    monitoring subfolders, allows filtering by file type, and incorporates a debounce 
    mechanism to avoid redundant operations on multiple changes in a short period.

.DESCRIPTION
    The script uses a FileSystemWatcher to monitor changes in the specified folder (and 
    optionally subfolders). It executes the `phpcbf` command on any `.php` file that has 
    been modified, ensuring code consistency by automatically fixing formatting issues. 
    The debounce mechanism ensures that only one action is triggered for rapid successive 
    changes (i.e., within the debounce interval).

.PARAMETER Path
    The folder path to monitor for changes. If not provided, it defaults to the current 
    directory.

.PARAMETER FileFilter
    The file type to monitor for changes (e.g., `*.php`, `*.js`). If not provided, it 
    defaults to `*.php`.

.EXAMPLE
    .\cs-watch.ps1 -Path "C:\Path\To\Directory" -FileFilter "*.php"
    This example will monitor the specified directory for `.php` file changes and run 
    `phpcbf` when changes are detected.

    .\cs-watch.ps1
    This example will monitor the current directory for `.php` file changes.

.NOTES
    Author: Daniele Soligo
    Date: 2025-04-26
	License: This script is released for free use under the following terms:
		- Free to use, modify, and distribute.
		- Provided "as-is" without any warranties of any kind, either express or implied, 
		  including but not limited to the warranties of merchantability, fitness for a 
		  particular purpose, or non-infringement.
		- The author is not responsible for any damages, loss of data, or other issues 
		  that may arise from the use of this script.
#>
param(
    [string]$Path = (Get-Location),   # Default to the current directory if no path is provided
    [string]$FileFilter = '*'     # Default to *.php if no file filter is provided
)


# Waits until a file stops changing before processing it.
# NetBeans and other IDEs save files through multiple rapid write/rename operations,
# which trigger several FileSystemWatcher events. This function checks that the file's
# size and LastWriteTime remain unchanged for a short period, ensuring the save
# operation is fully completed before continuing.
function global:Wait-FileStable {
    param(
        [string]$Path,
        [int]$StableMilliseconds = 500
    )

    $lastSize = -1
    $lastWrite = Get-Date

    while ($true) {
        if (-not (Test-Path $Path)) {
            Start-Sleep -Milliseconds 100
            continue
        }

        $info = Get-Item $Path
        $size = $info.Length
        $write = $info.LastWriteTime

        if ($size -eq $lastSize -and $write -eq $lastWrite) {
            Start-Sleep -Milliseconds $StableMilliseconds
            $info2 = Get-Item $Path
            if ($info2.Length -eq $size -and $info2.LastWriteTime -eq $write) {
                return
            }
        }

        $lastSize = $size
        $lastWrite = $write
        Start-Sleep -Milliseconds 100
    }
}


# Specify whether you want to monitor subfolders as well:
$IncludeSubfolders = $true

# Specify the file or folder properties you want to monitor:
$AttributeFilter = [IO.NotifyFilters]::FileName, [IO.NotifyFilters]::LastWrite

# Global debounce table and timeout
$global:LastChanged = @{}  # Initialize the global variable for LastChanged
$global:DebounceSeconds = 1  # Initialize the global variable for DebounceSeconds
$global:Cooldown = @{}

try {

    $watcher = New-Object -TypeName System.IO.FileSystemWatcher -Property @{
        Path = $Path
        Filter = $FileFilter
        IncludeSubdirectories = $IncludeSubfolders
        NotifyFilter = $AttributeFilter
    }

    # Define the action that should execute when a change occurs:
    $action = {
        # Accessing the global variables directly
        $details = $event.SourceEventArgs
        $FullPath = $details.FullPath
        $ChangeType = $details.ChangeType
        $Timestamp = $event.TimeGenerated
		
		# Cooldown per evitare loop con IDE
		if ($global:Cooldown.ContainsKey($FullPath)) {
			$last = $global:Cooldown[$FullPath]
			if ((Get-Date) -lt $last) {
				Write-Host "Cooldown attivo, ignoro: $FullPath" -ForegroundColor Gray
				return
			}
		}

        Write-Host "$FullPath was $ChangeType at $Timestamp" -ForegroundColor DarkYellow

        # Debounce check using global LastChanged
        $lastRun = $global:LastChanged[$FullPath]
        $now = Get-Date

        # Check debounce threshold (using global DebounceSeconds)
        if ($lastRun -and (($now - $lastRun).TotalSeconds -lt $global:DebounceSeconds)) {
            Write-Host "Debounced: $FullPath (processed $($now - $lastRun).TotalSeconds seconds ago)" -ForegroundColor Gray
            return
        }

        # Update the last change time for the file
        $global:LastChanged[$FullPath] = $now

        try {
			
			# Determine extension
			$ext = [System.IO.Path]::GetExtension($FullPath).ToLower()

			# List of PHP extensions
			$phpExtensions = @(".php", ".phtml", ".inc", ".module", ".install")

			# Ignore files that have no formatter
			if (($phpExtensions -notcontains $ext) -and ($ext -ne ".js")) {
				Write-Host "Ignoring file (no formatter configured): $FullPath" -ForegroundColor Gray
				return
			}

			# Wait for file stability once
			Write-Host "Waiting for file to become stable..."
			Wait-FileStable -Path $FullPath -StableMilliseconds 1000

			if ($phpExtensions -contains $ext) {
				Write-Host "Running phpcbf on: $FullPath"
				Start-Process -FilePath "phpcbf" -ArgumentList "-s $FullPath" -NoNewWindow -Wait
				$global:Cooldown[$FullPath] = (Get-Date).AddSeconds(1)

			}
			elseif ($ext -eq ".js") {
				Write-Host "Running eslint --fix on: $FullPath"

				$projectDir = Split-Path $FullPath -Parent
				$localEslint = Join-Path $projectDir "node_modules\.bin\eslint.cmd"

				if (Test-Path $localEslint) {
					$eslint = $localEslint
				} else {
					$eslint = Join-Path $env:APPDATA "npm\eslint.cmd"
				}

				Start-Process -FilePath $eslint `
					-ArgumentList "--fix `"$FullPath`"" `
					-WorkingDirectory $projectDir `
					-NoNewWindow -Wait
				
				$global:Cooldown[$FullPath] = (Get-Date).AddSeconds(1)
			}

            # Wait some time (optional)
            #Start-Sleep -Seconds 5

        } catch {
            Write-Host "Error running formatter: $_" -ForegroundColor Red
        }
    }

    # Subscribe your event handler to the Changed event:
    $handlers = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action -SourceIdentifier Changed

    # Monitoring starts now:
    $watcher.EnableRaisingEvents = $true

    Write-Host "Watching for changes to $Path"

    # Use an endless loop to keep PowerShell busy:
    do {
        Wait-Event -Timeout 3
        Write-Host "." -NoNewline
    } while ($true)
}
finally {
    # This gets executed when user presses CTRL+C:
    $watcher.EnableRaisingEvents = $false
    $handlers | ForEach-Object { Unregister-Event -SourceIdentifier $_.Name }
    $handlers | Remove-Job
    $watcher.Dispose()
    Write-Warning "Event Handler disabled, monitoring ends."
}
