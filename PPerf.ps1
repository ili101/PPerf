param($Work)

# restart PowerShell with -noexit, the same script, and 1
if ((!$Work) -and ($host.name -eq 'ConsoleHost')) {
    powershell.exe -noexit -file $MyInvocation.MyCommand.Path 1
    return
}
Write-Verbose -Message 'Version 2.27' -Verbose
# Set Variables
$SyncHash = [hashtable]::Synchronized(@{})
$SyncHash.Host = $host
$SyncHash.IperfFolder = $PSScriptRoot + '\bin'

# UI Runspace
$UiRunspace = [runspacefactory]::CreateRunspace()
$UiRunspace.ApartmentState = 'STA'
$UiRunspace.ThreadOptions = 'ReuseThread'
$UiRunspace.Open()
$UiRunspace.SessionStateProxy.SetVariable('syncHash',$SyncHash)

# UI Script
$UiPowerShell = [PowerShell]::Create().AddScript(
    {
        $SyncHash.host.ui.WriteVerboseLine(' UI Script Started')
        # Set Variables

        function Start-Iperf
        {
            $SyncHash.host.ui.WriteVerboseLine('Start-Iperf')
            if ($SyncHash.IperfJob.State -eq 'Running')
            {
                $SyncHash.host.ui.WriteVerboseLine('Iperf Already Running')
            }
            else
            {
                $SyncHash.host.ui.WriteVerboseLine('Iperf Start')
                $IperfScript =
                {
                    param($Command,$CsvFilePath,$IperfFolder)
                    Set-Location -Path $IperfFolder
                    'Time,localIp,localPort,RemoteIp,RemotePort,Id,Interval,Transfer,Bandwidth' | Out-File -FilePath $CsvFilePath
                    Invoke-Expression -Command $Command | Out-File -FilePath $CsvFilePath -Append
                    'Iperf Finished'
                }
                $SyncHash.IperfJob = Start-Job -ScriptBlock $IperfScript -ArgumentList $SyncHash.CommandTextBox.Text, $SyncHash.CsvFilePathTextBox.Text, $SyncHash.IperfFolder
                #Get-Job | Remove-Job -Force
                #$SyncHash.Remove('IperfJob')

                # Iperf Job Monitor with Register-ObjectEvent in Runspace

                if ($SyncHash.IperfJobMonitorRunspace)
                {
                    $SyncHash.host.ui.WriteVerboseLine('IperfJobMonitorRunspace Clean')
                    $SyncHash.host.ui.WriteVerboseLine('IperfJobMonitorEvent: ' + $SyncHash.IperfJobMonitorEvent.Error)
                    $SyncHash.IperfJobMonitorPowerShell.EndInvoke($SyncHash.IperfJobMonitorHandle)
                    $SyncHash.IperfJobMonitorRunspace.Close()
                    $SyncHash.IperfJobMonitorPowerShell.Dispose()
                }
                $SyncHash.IperfJobMonitorRunspace = [runspacefactory]::CreateRunspace()
                $SyncHash.IperfJobMonitorRunspace.ApartmentState = 'STA'
                $SyncHash.IperfJobMonitorRunspace.ThreadOptions = 'ReuseThread'
                $SyncHash.IperfJobMonitorRunspace.Open()
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('syncHash',$SyncHash)
                $SyncHash.IperfJobMonitorPowerShell = [PowerShell]::Create().AddScript(
                {
                    function Stop-Iperf
                    {
                        $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf')
                        if ($SyncHash.IperfJob)
                        {
                            if ($SyncHash.IperfJob.state -eq 'Completed')
                            {
                                $SyncHash.host.ui.WriteVerboseLine('Iperf Receive Job')
                                $SyncHash.IperfJobOutputTextBox.Text = $SyncHash.IperfJob | Receive-Job 2>&1
                            }
                            else
                            {
                                $SyncHash.host.ui.WriteVerboseLine('Iperf Stop Job')
                                $SyncHash.IperfJobOutputTextBox.Text = $SyncHash.IperfJob | Stop-Job 2>&1
                            }
                            $SyncHash.IperfJob | Remove-Job
                            Remove-Variable -Name SyncHash.IperfJob
                            #Get-Job | Remove-Job -Force
                        }
                    }
                    $SyncHash.IperfJobMonitorEvent = Register-ObjectEvent -InputObject $SyncHash.IperfJob -EventName StateChanged -MessageData $SyncHash.IperfJob.Id -SourceIdentifier IperfJobMonitor -Action {
                    $SyncHash.host.ui.WriteVerboseLine('Iperf Job Finished')
                    Stop-Iperf
                }
                #Get-EventSubscriber | Unregister-Event
                #$SyncHash.Remove('IperfJobMonitor')
                })
                $SyncHash.IperfJobMonitorPowerShell.Runspace = $SyncHash.IperfJobMonitorRunspace
                $SyncHash.IperfJobMonitorHandle = $SyncHash.IperfJobMonitorPowerShell.BeginInvoke()
            }
        }

        function Global:Stop-Iperf
        {
            $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf')
            if ($SyncHash.IperfJob)
            {
                if ($SyncHash.IperfJob.state -eq 'Completed')
                {
                    $SyncHash.host.ui.WriteVerboseLine('Iperf Receive Job')
                    $SyncHash.IperfJobOutputTextBox.Text = $SyncHash.IperfJob | Receive-Job 2>&1
                }
                else
                {
                    $SyncHash.host.ui.WriteVerboseLine('Iperf Stop Job')
                    $SyncHash.IperfJobOutputTextBox.Text = $SyncHash.IperfJob | Stop-Job 2>&1
                }
                $SyncHash.IperfJob | Remove-Job
                Remove-Variable -Name SyncHash.IperfJob
                #Get-Job | Remove-Job -Force
            }
        }

        function Start-Analyzer
        {
            $SyncHash.host.ui.WriteVerboseLine('Start-Analyzer')
            if ($SyncHash.AnalyzerRunspace.RunspaceStateInfo.State -eq 'Opened')
            {
                $SyncHash.host.ui.WriteVerboseLine('Analyzer Already Running')
            }
            else
            {
                # Analyzer Runspace
                $SyncHash.AnalyzerRunspace = [runspacefactory]::CreateRunspace()
                $SyncHash.AnalyzerRunspace.ApartmentState = 'STA'
                $SyncHash.AnalyzerRunspace.ThreadOptions = 'ReuseThread'
                $SyncHash.AnalyzerRunspace.Open()
                $SyncHash.AnalyzerRunspace.SessionStateProxy.SetVariable('syncHash',$SyncHash)

                $SyncHash.AnalyzerPowerShell = [powershell]::Create()
                $SyncHash.AnalyzerPowerShell.Runspace = $SyncHash.AnalyzerRunspace
                $null = $SyncHash.AnalyzerPowerShell.AddScript($AnalyzerScript)
                $SyncHash.host.ui.WriteVerboseLine('Start-Analyzer')
                $SyncHash.AnalyzerHandle = $SyncHash.AnalyzerPowerShell.BeginInvoke()
            }
        }

        function Stop-Analyzer
        {
            $SyncHash.host.ui.WriteVerboseLine('Stop-Analyzer')
            $SyncHash.AnalyzerRunspace.Close()
            $SyncHash.AnalyzerPowerShell.Dispose()
        }

        function Set-IperfCommand
        {
            if ($SyncHash.ClientRadio.Checked)
            {
                $IperfMode = ' -c ' + $SyncHash.IpTextBox.Text
                $SyncHash.IpTextBox.Enabled = $true
                $IperfTime = ' -t ' + $SyncHash.TimeTextBox.Text
                $SyncHash.TimeTextBox.Enabled = $true
            }
            else
            {
                $IperfMode = ' -s'
                $SyncHash.IpTextBox.Enabled = $false
                $IperfTime = $null
                $SyncHash.TimeTextBox.Enabled = $false
            }
            $SyncHash.CommandTextBox.Text = '.\iperf.exe' + $IperfMode + $IperfTime + ' -y c -i 1'
        }

        [void][reflection.assembly]::LoadWithPartialName('System.Windows.Forms')
        [void][Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms.DataVisualization')

        # Create chart
        $SyncHash.Chart = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.Chart

        # Add chart area to chart
        $SyncHash.ChartArea = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.ChartArea
        $SyncHash.Chart.ChartAreas.Add($SyncHash.ChartArea)

        [void]$SyncHash.Chart.Series.Add('Bandwidth (Mbits/sec)')
        [void]$SyncHash.Chart.Series.Add('Transfer (MBytes)')

        # Display the chart on a form
        $SyncHash.Chart.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        $SyncHash.Chart.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (0, 100)
        $SyncHash.Chart.BackColor = [System.Drawing.Color]::Transparent
        $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::'Line'
        $SyncHash.Chart.Series['Transfer (MBytes)'].ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::'Line'
        $SyncHash.Chart.Width = 800
        $SyncHash.ChartLegend = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.Legend
        [void]$SyncHash.Chart.Legends.Add($SyncHash.ChartLegend)

        $SyncHash.Form = New-Object -TypeName Windows.Forms.Form
        $SyncHash.Form.Text = 'PowerShell Chart'
        $SyncHash.Form.Width = $SyncHash.Chart.Width + 15
        $SyncHash.Form.Height = $SyncHash.Chart.Height + 145
        $SyncHash.Form.controls.add($SyncHash.Chart)
        #$SyncHash.Form.Invoke([action]{$SyncHash.Form.controls.add($SyncHash.Chart)})

        # Start Iperf Button
        $SyncHash.StartIperfButton = New-Object -TypeName System.Windows.Forms.Button
        $SyncHash.StartIperfButton.Text = 'Start Iperf'
        $SyncHash.StartIperfButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (0, 0)
        $SyncHash.StartIperfButton.Add_Click({Start-Iperf})
        $SyncHash.Form.Controls.Add($SyncHash.StartIperfButton)

        # Stop Iperf Button
        $SyncHash.StopIperfButton = New-Object -TypeName System.Windows.Forms.Button
        $SyncHash.StopIperfButton.Text = 'Stop Iperf'
        $SyncHash.StopIperfButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (75, 0)
        $SyncHash.StopIperfButton.Add_Click({Stop-Iperf})
        $SyncHash.Form.Controls.Add($SyncHash.StopIperfButton)

        # Start Analyzer Button
        $SyncHash.StartAnalyzerButton = New-Object -TypeName System.Windows.Forms.Button
        $SyncHash.StartAnalyzerButton.Text = 'Start Analyzer'
        $SyncHash.StartAnalyzerButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (0, 25)
        $SyncHash.StartAnalyzerButton.Add_Click({Start-Analyzer})
        $SyncHash.Form.Controls.Add($SyncHash.StartAnalyzerButton)

        # Stop Analyzer Button
        $SyncHash.StopAnalyzerButton = New-Object -TypeName System.Windows.Forms.Button
        $SyncHash.StopAnalyzerButton.Text = 'Stop Analyzer'
        $SyncHash.StopAnalyzerButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (75, 25)
        $SyncHash.StopAnalyzerButton.Add_Click({Stop-Analyzer})
        $SyncHash.Form.Controls.Add($SyncHash.StopAnalyzerButton)

        # IP TextBox
        $SyncHash.IpTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.IpTextBox.Left = 0
        $SyncHash.IpTextBox.Top = 50
        #$SyncHash.IpTextBox.width = 200
        $SyncHash.IpTextBox.Text = '127.0.0.1'
        $SyncHash.IpTextBox.add_TextChanged({Set-IperfCommand})
        $SyncHash.Form.Controls.Add($SyncHash.IpTextBox)

        # Time TextBox
        $SyncHash.TimeTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.TimeTextBox.Left = 100
        $SyncHash.TimeTextBox.Top = 50
        #$SyncHash.TimeTextBox.width = 200
        $SyncHash.TimeTextBox.Text = 60
        $SyncHash.TimeTextBox.add_TextChanged({Set-IperfCommand})
        $SyncHash.Form.Controls.Add($SyncHash.TimeTextBox)

        # Command TextBox
        $SyncHash.CommandTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.CommandTextBox.Left = 0
        $SyncHash.CommandTextBox.Top = 75
        $SyncHash.CommandTextBox.width = 200
        $SyncHash.Form.Controls.Add($SyncHash.CommandTextBox)

        # Server or Client GroupBox
        $SyncHash.ModeGroupBox = New-Object -TypeName System.Windows.Forms.GroupBox
        $SyncHash.ModeGroupBox.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (400, 0)
        $SyncHash.ModeGroupBox.size = New-Object -TypeName System.Drawing.Size -ArgumentList (100, 80)
        $SyncHash.ModeGroupBox.text = 'Server or Client'
        $SyncHash.Form.Controls.Add($SyncHash.ModeGroupBox)

        # Client or Server RadioButtons
        $SyncHash.ClientRadio = New-Object -TypeName System.Windows.Forms.RadioButton
        $SyncHash.ClientRadio.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (15, 15)
        $SyncHash.ClientRadio.size = New-Object -TypeName System.Drawing.Size -ArgumentList (80, 20)
        $SyncHash.ClientRadio.Checked = $true
        $SyncHash.ClientRadio.Text = 'Client'
        $SyncHash.ClientRadio.add_CheckedChanged({Set-IperfCommand})
        $SyncHash.ModeGroupBox.Controls.Add($SyncHash.ClientRadio)

        $SyncHash.ServerRadio = New-Object -TypeName System.Windows.Forms.RadioButton
        $SyncHash.ServerRadio.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (15, 45)
        $SyncHash.ServerRadio.size = New-Object -TypeName System.Drawing.Size -ArgumentList (80, 20)
        $SyncHash.ServerRadio.Text = 'Server'
        $SyncHash.ModeGroupBox.Controls.Add($SyncHash.ServerRadio)

        # Csv SaveFileDialog
        $CsvSaveFileDialog = New-Object -TypeName System.Windows.Forms.SaveFileDialog
        $CsvSaveFileDialog.Filter = 'Comma Separated|*.csv|All files|*.*'
        $CsvSaveFileDialog.FileName = ([Environment]::GetFolderPath('Desktop') + '\iperf.csv')

        # Csv File Path TextBox
        $SyncHash.CsvFilePathTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.CsvFilePathTextBox.Left = 150
        $SyncHash.CsvFilePathTextBox.Top = 25
        $SyncHash.CsvFilePathTextBox.width = 200
        $SyncHash.CsvFilePathTextBox.Text = $CsvSaveFileDialog.FileName
        $SyncHash.Form.Controls.Add($SyncHash.CsvFilePathTextBox)

        # Browse Button
        $CsvFilePathButton = New-Object -TypeName System.Windows.Forms.Button
        $CsvFilePathButton.Text = 'Browse'
        $CsvFilePathButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (150, 0)
        $CsvFilePathButton.Add_Click({
                $CsvSaveFileDialog.ShowDialog()
                $SyncHash.CsvFilePathTextBox.Text = $CsvSaveFileDialog.FileName
            }
        )
        $SyncHash.Form.Controls.Add($CsvFilePathButton)

        # Iperf Job Output TextBox
        $SyncHash.IperfJobOutputTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.IperfJobOutputTextBox.Left = 200
        $SyncHash.IperfJobOutputTextBox.Top = 75
        $SyncHash.IperfJobOutputTextBox.width = 200
        $SyncHash.Form.Controls.Add($SyncHash.IperfJobOutputTextBox)

        # Max Scale TextBox
        $SyncHash.MaxScaleTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.MaxScaleTextBox.Left = 225
        $SyncHash.MaxScaleTextBox.Top = 0
        $SyncHash.MaxScaleTextBox.width = 50
        $SyncHash.MaxScaleTextBox.Text = $SyncHash.Chart.ChartAreas[0].Axisy.Maximum
        $SyncHash.MaxScaleTextBox.add_TextChanged({$SyncHash.Chart.ChartAreas[0].Axisy.Maximum = $SyncHash.MaxScaleTextBox.Text})
        $SyncHash.Form.Controls.Add($SyncHash.MaxScaleTextBox)

        # LastX TextBox
        $SyncHash.LastXTextBox = New-Object -TypeName 'System.Windows.Forms.TextBox'
        $SyncHash.LastXTextBox.Left = 275
        $SyncHash.LastXTextBox.Top = 0
        $SyncHash.LastXTextBox.width = 50
        $SyncHash.LastXTextBox.Text = 0
        $SyncHash.LastXTextBox.add_TextChanged({})
        $SyncHash.Form.Controls.Add($SyncHash.LastXTextBox)

        Set-IperfCommand

        # Analyzer Runspace Script
        $AnalyzerScript = 
        {
            $SyncHash.host.ui.WriteVerboseLine('Analyzer')
            
            $AnalyzerData = New-Object -TypeName System.Collections.Generic.List[System.Object]
            Get-Content -Path $SyncHash.CsvFilePathTextBox.Text | ConvertFrom-Csv | ForEach-Object -Process {
                $_.Bandwidth = $_.Bandwidth /1Mb
                $_.Transfer = $_.Transfer /1Mb
                if (!($_.Interval).StartsWith('0.0-') -or ($_.Interval -eq'0.0-1.0'))
                {
                    $AnalyzerData.add($_)
                }   
                else  
                {
                    $SyncHash.host.ui.WriteVerboseLine('Remove Total ' + $_.Time)
                }           
                
            }
            $AnalyzerDataLength = $AnalyzerData.Count

            $SyncHash.host.ui.WriteVerboseLine(($AnalyzerDataLength | Out-String) + ($AnalyzerData[$AnalyzerDataLength-1] | Out-String))

            if ($AnalyzerDataLength -gt $SyncHash.LastXTextBox.Text -and $SyncHash.LastXTextBox.Text -gt 0)
                {
                    $SyncHash.host.ui.WriteVerboseLine('Trim 1')
                    $TrimedData =$AnalyzerData.GetRange($AnalyzerDataLength - $SyncHash.LastXTextBox.Text, $SyncHash.LastXTextBox.Text)
                    $ChartDataAction1 = [Action]{
                        $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.DataBindXY($TrimedData.Interval, $TrimedData.Bandwidth)
                        $SyncHash.Chart.Series['Transfer (MBytes)'].Points.DataBindXY($TrimedData.Interval, $TrimedData.Transfer)
                    }
                }
            else
            {
                $ChartDataAction1 = [Action]{
                    $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.DataBindXY($AnalyzerData.Interval, $AnalyzerData.Bandwidth)
                    $SyncHash.Chart.Series['Transfer (MBytes)'].Points.DataBindXY($AnalyzerData.Interval, $AnalyzerData.Transfer)
                }
            }
            $SyncHash.Chart.Invoke($ChartDataAction1)

            Get-Content -Path $SyncHash.CsvFilePathTextBox.Text -Wait -Tail 1 | ConvertFrom-Csv -Header Time,localIp,localPort,RemoteIp,RemotePort,Id,Interval,Transfer,Bandwidth | ForEach-Object -Process {
                if (!($_.Interval).StartsWith('0.0-') -or ($_.Interval -eq'0.0-1.0'))
                {
                    $_.Bandwidth = $_.Bandwidth /1Mb
                    $_.Transfer = $_.Transfer /1Mb
                    
                    $AnalyzerData.add($_)
                    $AnalyzerDataLength++
                    #$SyncHash.host.ui.WriteVerboseLine($_)
                    #$SyncHash.host.ui.WriteVerboseLine($AnalyzerDataLength)
                    $AnalyzerDataLine = $_

                    if ($AnalyzerDataLength -gt -1)
                    {
                        $ChartDataAction2 = [Action]{
                            if ($AnalyzerDataLength -gt $SyncHash.LastXTextBox.Text -and $SyncHash.LastXTextBox.Text -gt 0)
                            {
                                $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.RemoveAt(0)
                                $SyncHash.Chart.Series['Transfer (MBytes)'].Points.RemoveAt(0)
                            }
                            $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.AddXY($AnalyzerDataLine.Interval, $AnalyzerDataLine.Bandwidth)
                            $SyncHash.Chart.Series['Transfer (MBytes)'].Points.AddXY($AnalyzerDataLine.Interval, $AnalyzerDataLine.Transfer)
                            $SyncHash.host.ui.WriteVerboseLine('Test: ' + ($SyncHash.Chart.Series['Transfer (MBytes)'].Points.Count | Out-String))
                        }
                        $SyncHash.Chart.Invoke($ChartDataAction2)
                        $SyncHash.MaxScaleTextBox.Text = $SyncHash.Chart.ChartAreas[0].Axisy.Maximum
                    }
                    #$SyncHash.host.ui.WriteVerboseLine(($AnalyzerData | Out-String))
                }
                else  
                {
                    $SyncHash.host.ui.WriteVerboseLine('Remove Total2 ' + $_.Time)
                }   

            }
        }

        $SyncHash.Form.Add_Shown({$SyncHash.Form.Activate()})
        $null = $SyncHash.Form.ShowDialog()

        # Clean
        if ($SyncHash.IperfJob)
        {
            $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf End')
            Stop-Iperf
        }

        $SyncHash.host.ui.WriteVerboseLine('Stop-Analyzer End')
        Stop-Analyzer
        
        $SyncHash.AnalyzerRunspace.Close()
        $SyncHash.AnalyzerPowerShell.Dispose()
        $SyncHash.Error = $Error
    }
)

$UiPowerShell.Runspace = $UiRunspace
$UiHandle = $UiPowerShell.BeginInvoke()
#$UiPowerShell.EndInvoke($UiHandle)
#$SyncHash.Error
#$UiPowerShell.Streams

#$SyncHash.AnalyzerPowerShell.Streams
#$SyncHash.AnalyzerPowerShell.EndInvoke($handle)

#[void][System.Windows.Forms.MessageBox]::Show("2","1")
