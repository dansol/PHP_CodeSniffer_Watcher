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
    [string]$FileFilter = '*.php'     # Default to *.php if no file filter is provided
)


# Specify whether you want to monitor subfolders as well:
$IncludeSubfolders = $true

# Specify the file or folder properties you want to monitor:
$AttributeFilter = [IO.NotifyFilters]::FileName, [IO.NotifyFilters]::LastWrite

# Global debounce table and timeout
$global:LastChanged = @{}  # Initialize the global variable for LastChanged
$global:DebounceSeconds = 10  # Initialize the global variable for DebounceSeconds

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
            # Run phpcbf command on the changed file
            Write-Host "Running phpcbf on: $FullPath"
            $proc = Start-Process -FilePath "phpcbf" -ArgumentList "-s $FullPath" -NoNewWindow -PassThru -Wait
			$proc.WaitForExit()  # Ensure the script waits until the process finishes

            # Wait some time (optional)
            Start-Sleep -Seconds 5

        } catch {
            Write-Host "Error running phpcbf: $_" -ForegroundColor Red
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
