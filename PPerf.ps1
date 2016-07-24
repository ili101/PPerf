#requires -Version 3
param($Work)

# restart PowerShell with -noexit, the same script, and 1
if ((!$Work) -and ($host.name -eq 'ConsoleHost')) 
{
    powershell.exe -noexit -file $MyInvocation.MyCommand.Path 1
    return
}

# Set Variables
$SyncHash = [hashtable]::Synchronized(@{})
$SyncHash.Host = $host
$SyncHash.IperfFolder = $PSScriptRoot + '\Bin'

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
        trap {$SyncHash.host.ui.WriteErrorLine("$_`nError was in Line {0}`n{1}" -f ($_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line))}

        function Write-Status
        {
        [CmdletBinding()]
            param
            (
                [Parameter(Mandatory=$true, Position=0)]
                [String]$Text,
                
                [Parameter(Mandatory=$true, Position=1)]
                [String]$Colore
            )
            $syncHash.Form.Dispatcher.invoke([action]{
                    if (![string]::IsNullOrWhitespace([System.Windows.Documents.TextRange]::new($SyncHash.IperfJobOutputTextBox.Document.ContentStart, $SyncHash.IperfJobOutputTextBox.Document.ContentEnd).Text))
                    {
                        $SyncHash.IperfJobOutputTextBox.AppendText("`r")
                    }
                    
                    $TextRange = [System.Windows.Documents.TextRange]::new($SyncHash.IperfJobOutputTextBox.Document.ContentEnd, $SyncHash.IperfJobOutputTextBox.Document.ContentEnd)
                    $TextRange.Text = $Text
                    $TextRange.ApplyPropertyValue([System.Windows.Documents.TextElement]::ForegroundProperty, [System.Windows.Media.Brushes]::$Colore)
                    $SyncHash.IperfJobOutputTextBox.ScrollToEnd()
            })
        }

        function Start-Iperf
        {
            $SyncHash.host.ui.WriteVerboseLine('Start-Iperf')
            if ($SyncHash.IperfJobMonitorRunspace.RunspaceStateInfo.State -eq 'Opened')
            {
                Write-Status -Text 'Iperf Already Running' -Colore 'Orange'
            }
            else
            {

                #Get-Job | Remove-Job -Force
                #$SyncHash.Remove('IperfJob')

                # Iperf Job Monitor with Register-ObjectEvent in Runspace
                $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                $InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Stop-Iperf', (Get-Content Function:\Stop-Iperf)))
                $InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Write-Status', (Get-Content Function:\Write-Status)))
                $SyncHash.IperfJobMonitorRunspace = [runspacefactory]::CreateRunspace($InitialSessionState)
                $SyncHash.IperfJobMonitorRunspace.ApartmentState = 'STA'
                $SyncHash.IperfJobMonitorRunspace.ThreadOptions = 'ReuseThread'
                $SyncHash.IperfJobMonitorRunspace.Open()
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('syncHash',$SyncHash)
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('CsvFilePath',$SyncHash.CsvFilePathTextBox.Text)
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('Command',$SyncHash.CommandTextBox.Text)
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('IperfVersion',$IperfVersion)
                $SyncHash.IperfJobMonitorRunspace.SessionStateProxy.SetVariable('IperfExe',$IperfExe)
                $SyncHash.IperfJobMonitorPowerShell = [PowerShell]::Create().AddScript(
                    {
                        trap {$SyncHash.host.ui.WriteErrorLine("$_`nError was in Line {0}`n{1}" -f ($_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line))}
                        trap [System.Management.Automation.PipelineStoppedException] {$SyncHash.host.ui.WriteVerboseLine($_)}
                        
                        $SyncHash.host.ui.WriteVerboseLine('Start-Iperf Running')
                        Set-Location -Path $SyncHash.IperfFolder
                        
                        try
                        {
                            $ErrorActionPreferenceOrg = $ErrorActionPreference
                            if ($IperfVersion -eq 2)
                            {
                                'Time,localIp,localPort,RemoteIp,RemotePort,Id,Interval,Transfer,Bandwidth' | Out-File -FilePath $CsvFilePath
                                Write-Status -Text ((Invoke-Expression -Command "$IperfExe -v") 2>&1) -Colore 'Blue'
                                $ErrorActionPreference = 'stop'
                                Invoke-Expression -Command $Command | Out-File -FilePath $CsvFilePath -Append
                            }
                            else
                            {
                                Set-Content -Path $CsvFilePath -Value $null
                                #Write-Status -Text ((Invoke-Expression -Command "$IperfExe -v") -join ' ') -Colore 'Blue'
                                Invoke-Expression -Command $Command

                                if ($ErrorOut = Get-Content -Tail 5 -Path $CsvFilePath | Select-String -Pattern 'iperf3: error')
                                {
                                    Write-Error -Message $ErrorOut -ErrorAction Stop
                                }
                            }
                        }
                        catch
                        {
                            Write-Status -Text $_ -Colore 'Red'
                            Stop-Iperf
                        }
                        $ErrorActionPreference = $ErrorActionPreferenceOrg
                        Write-Status -Text 'Iperf Finished' -Colore 'Green'
                        Stop-Iperf

                        #Get-EventSubscriber | Unregister-Event
                        #$SyncHash.Remove('IperfJobMonitor')
                    })
                $SyncHash.IperfJobMonitorPowerShell.Runspace = $SyncHash.IperfJobMonitorRunspace
                $SyncHash.IperfJobMonitorHandle = $SyncHash.IperfJobMonitorPowerShell.BeginInvoke()
            }
        }

        function Stop-Iperf
        {
            $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf')
            if ($SyncHash.IperfJobMonitorRunspace.RunspaceStateInfo.State -eq 'Opened')
            {
                $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf Running')
                #$SyncHash.IperfJobMonitorPowerShell.EndInvoke($SyncHash.IperfJobMonitorHandle)
                $SyncHash.IperfJobMonitorRunspace.Close()
                $SyncHash.IperfJobMonitorPowerShell.Dispose()
            }
        }

        function Start-Analyzer
        {
            $SyncHash.host.ui.WriteVerboseLine('Start-Analyzer')
            if (!(Test-Path -Path $SyncHash.CsvFilePathTextBox.Text))
            {
                Write-Status -Text 'File not found' -Colore 'Red'
            }
            elseif ($SyncHash.AnalyzerRunspace.RunspaceStateInfo.State -eq 'Opened')
            {
                Write-Status -Text 'Analyzer Already Running' -Colore 'Orange'
            }
            else
            {
                # Analyzer Runspace
                $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                $InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Stop-Analyzer', (Get-Content Function:\Stop-Analyzer)))
                $InitialSessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Write-Status', (Get-Content Function:\Write-Status)))
                $SyncHash.AnalyzerRunspace = [runspacefactory]::CreateRunspace($InitialSessionState)
                $SyncHash.AnalyzerRunspace.ApartmentState = 'STA'
                $SyncHash.AnalyzerRunspace.ThreadOptions = 'ReuseThread'
                $SyncHash.AnalyzerRunspace.Open()
                $SyncHash.AnalyzerRunspace.SessionStateProxy.SetVariable('syncHash',$SyncHash)
                $SyncHash.AnalyzerRunspace.SessionStateProxy.SetVariable('CsvFilePath',$SyncHash.CsvFilePathTextBox.Text)
                $SyncHash.AnalyzerRunspace.SessionStateProxy.SetVariable('LastX',$SyncHash.LastXTextBox.Text)
                $SyncHash.AnalyzerRunspace.SessionStateProxy.SetVariable('IperfVersion',$IperfVersion)
                $SyncHash.AnalyzerPowerShell = [powershell]::Create()
                $SyncHash.AnalyzerPowerShell.Runspace = $SyncHash.AnalyzerRunspace
                $null = $SyncHash.AnalyzerPowerShell.AddScript($AnalyzerScript)
                $SyncHash.AnalyzerHandle = $SyncHash.AnalyzerPowerShell.BeginInvoke()
            }
        }

        # Analyzer Runspace Script
        $AnalyzerScript = 
        {
            $SyncHash.host.ui.WriteVerboseLine('Start-Analyzer Running')
            trap {$SyncHash.host.ui.WriteErrorLine("$_`nError was in Line {0}`n{1}" -f ($_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line))}
            trap [System.Management.Automation.PipelineStoppedException] {$SyncHash.host.ui.WriteVerboseLine($_)}

            $First  = $true
            $Header = $null
            $AnalyzerDataLength = 0

            $ChartDataAction0 = [Action]{
                $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.Clear()
                $SyncHash.Chart.Series['Transfer (MBytes)'].Points.Clear()
                $SyncHash.host.ui.WriteVerboseLine('Clear Data: ' + ($SyncHash.Chart.Series['Transfer (MBytes)'].Points.Count | Out-String))
            }
            $SyncHash.Chart.Invoke($ChartDataAction0)

            Get-Content -Path $CsvFilePath -ReadCount 0 -Wait | ForEach-Object {
                trap {$SyncHash.host.ui.WriteErrorLine("$_`nError was in Line {0}`n{1}" -f ($_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line))}
                #$SyncHash.host.ui.WriteVerboseLine('Loop Data: ' + ($_ | Out-String)) ###
                $AnalyzerData = New-Object -TypeName System.Collections.Generic.List[System.Object]

                if ($IperfVersion -eq 2)
                {
                    foreach ($Line in $_)
                    {
                        if ($Line -like '*Bandwidth*')
                        {
                            $Header = $Line -split ','
                        }
                        else
                        {
                            if ($First -and !$Header)
                            {
                                Write-Status -Text 'CSV Error' -Colore 'Red'
                                Stop-Analyzer
                            }
                            else
                            {
                                $First = $false
                            }

                            $CsvLine = $Line | ConvertFrom-Csv -Header $Header
                            $CsvLine.Bandwidth = $CsvLine.Bandwidth /1Mb
                            $CsvLine.Transfer = $CsvLine.Transfer /1Mb
                            if (!($CsvLine.Interval).StartsWith('0.0-') -or ($CsvLine.Interval -eq '0.0-1.0'))
                            {
                                $AnalyzerData.add($CsvLine)
                            }   
                            else  
                            {
                                $SyncHash.host.ui.WriteVerboseLine('Remove Total Line: ' + $CsvLine.Time)
                            }
                        }
                    }
                }
                else
                {
                    $Csv = $_ | Where-Object {$_ -match '\[...\]'}
                    #$Csv = $a | Select-String -Pattern '\[...\]'
                    foreach ($Line in $Csv)
                    {
                        $Line = $Line -replace '[][]'
                        if ($Line -like ' ID *')
                        {
                            $Header = $Line -split '\s+' | Where-Object {$_}
                            $HeaderIndex = @()
                            foreach ($Head in $Header)
                            {
                                $HeaderIndex += $Line.IndexOf($Head)
                            }
                        }
                        elseif ($Header -and $Line -notlike '*connected to*' -and $Line -notlike '*sender*' -and $Line -notlike '*receiver*')
                        {
                            $i=0
                            $CsvLine = New-Object System.Object
                            foreach ($Head in $Header)
                            {
                                if ($i -lt $HeaderIndex.Length-1)
                                {
                                    $Cell = $Line.Substring($HeaderIndex[$i],$HeaderIndex[$i + 1] - $HeaderIndex[$i])
                                }
                                else
                                {
                                    $Cell = $Line.Substring($HeaderIndex[$i])
                                }

                                if ($Head -eq 'Transfer')
                                {
                                    $TransferData = $Cell.Trim() -split '\s+'
                                    if ($TransferData[1] -eq 'KBytes')
                                    {
                                        $Cell = $TransferData[0] /1kb
                                    }
                                    elseif ($TransferData[1] -eq 'GBytes')
                                    {
                                        $Cell = $TransferData[0] *1kb
                                    }
                                }

                                $i++
                                Add-Member -InputObject $CsvLine -NotePropertyName $Head -NotePropertyValue ("$Cell".Trim() -split '\s+')[0]
                            }
                            $AnalyzerData.add($CsvLine)
                        }
                    }
                }

                if ($AnalyzerData.Count -gt $LastX -and $LastX -gt 0)
                {
                    $SyncHash.host.ui.WriteVerboseLine('Trim Data 1')
                    $AnalyzerData = $AnalyzerData.GetRange($AnalyzerData.Count - $LastX, $LastX)
                }
                $SyncHash.host.ui.WriteVerboseLine('New Points: ' + $AnalyzerData.Count)

                if ($AnalyzerData.Count -gt 0)
                {
                    if ($AnalyzerDataLength -eq 0 -and $AnalyzerData.Count -gt 1)
                    {
                        $ChartDataAction1 = [Action]{
                            $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.DataBindXY($AnalyzerData.Interval, $AnalyzerData.Bandwidth)
                            $SyncHash.Chart.Series['Transfer (MBytes)'].Points.DataBindXY($AnalyzerData.Interval, $AnalyzerData.Transfer)
                            $SyncHash.host.ui.WriteVerboseLine('Show Data: ' + ($SyncHash.Chart.Series['Transfer (MBytes)'].Points.Count | Out-String))
                        }
                        $SyncHash.Chart.Invoke($ChartDataAction1)
                    }
                    else
                    {
                        $ChartDataAction2 = [Action]{
                            while ($AnalyzerDataLength + $AnalyzerData.Count -gt $LastX -and $LastX -gt 0)
                            {
                                $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.RemoveAt(0)
                                $SyncHash.Chart.Series['Transfer (MBytes)'].Points.RemoveAt(0)
                                $Global:AnalyzerDataLength --
                            }
                            foreach ($Point in $AnalyzerData)
                            {
                                $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].Points.AddXY($Point.Interval, $Point.Bandwidth)
                                $SyncHash.Chart.Series['Transfer (MBytes)'].Points.AddXY($Point.Interval, $Point.Transfer)
                                $SyncHash.host.ui.WriteVerboseLine('Add Data Point: ' + ($SyncHash.Chart.Series['Transfer (MBytes)'].Points.Count | Out-String))
                            }
                        }
                        $SyncHash.Chart.Invoke($ChartDataAction2)
                    }
                    $AnalyzerDataLength += $AnalyzerData.Count
                }
                else
                {
                    $SyncHash.host.ui.WriteVerboseLine('Point Skipped')
                }
                $SyncHash.host.ui.WriteVerboseLine('Analyzer Loop End: ' + ($AnalyzerDataLength | Out-String))
            }
        }

        function Stop-Analyzer
        {
            $SyncHash.host.ui.WriteVerboseLine('Stop-Analyzer')
            if ($SyncHash.AnalyzerRunspace.RunspaceStateInfo.State -eq 'Opened')
            {
                $SyncHash.host.ui.WriteVerboseLine('Stop-Analyzer Running')
                $SyncHash.AnalyzerRunspace.Close()
                $SyncHash.AnalyzerPowerShell.Dispose()
            }
        }

        function Set-IperfCommand
        {
            if ($SyncHash.ClientRadio.IsChecked)
            {
                $IperfMode = ' -c ' + $SyncHash.IpTextBox.Text
                $SyncHash.IpTextBox.IsEnabled = $true
                $IperfTime = ' -t ' + $SyncHash.TimeTextBox.Text
                $SyncHash.TimeTextBox.IsEnabled = $true
            }
            else
            {
                $IperfMode = ' -s'
                $SyncHash.IpTextBox.IsEnabled = $false
                $IperfTime = $null
                $SyncHash.TimeTextBox.IsEnabled = $false
            }

            if ($SyncHash.Version2Radio.IsChecked)
            {
                $IperfVersionParams = ' -y c'
                $Global:IperfVersion = 2
                $Global:IperfExe = '.\iperf.exe'
            }
            else
            {
                $IperfVersionParams = ' -f m --logfile ' + $SyncHash.CsvFilePathTextBox.Text
                $Global:IperfVersion = 3
                $Global:IperfExe = '.\iperf3.exe'
            }

            $SyncHash.CommandTextBox.Text = $IperfExe + $IperfMode + $IperfTime + $IperfVersionParams + ' -i 1'
        }

        # UI
        $InputXml = @"
<Window x:Class="PPerf.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:PPerf"
        xmlns:wf="clrnamespace:System.Windows.Forms;assembly=System.Windows.Forms"
        xmlns:wfi="clr-namespace:System.Windows.Forms;assembly=WindowsFormsIntegration"
        mc:Ignorable="d"
        Title="PPerf" Height="680" Width="670">
    <Grid>
        <GroupBox x:Name="CsvFileGroupBox" Header="CSV File" Height="65" Margin="10,10,10,0" VerticalAlignment="Top">
            <Grid Margin="0">
                <Button x:Name="CsvFilePathButton" Content="_Browse" HorizontalAlignment="Left" Margin="10,0,0,0" Width="75" Height="20" VerticalAlignment="Center"/>
                <TextBox x:Name="CsvFilePathTextBox" Margin="90,9,10,9" TextWrapping="Wrap" Text="CSV File" Height="20" VerticalAlignment="Center"/>
            </Grid>
        </GroupBox>
        <RichTextBox x:Name="IperfJobOutputTextBox" Margin="10,0,10,10" VerticalScrollBarVisibility="Auto" Height="52" VerticalAlignment="Bottom"/>
        <GroupBox x:Name="iPerfGroupBox" Header="iPerf" Height="145" Margin="10,80,10,0" VerticalAlignment="Top">
            <Grid Margin="0">
                <GroupBox x:Name="ModeGroupBox" Header="Server or Client" Height="82" Margin="0,0,10,0" VerticalAlignment="Top" HorizontalAlignment="Right" Width="100">
                    <Grid Margin="0">
                        <RadioButton x:Name="ClientRadio" Content="Client" HorizontalAlignment="Left" Margin="10,10,0,0" VerticalAlignment="Top" IsChecked="True"/>
                        <RadioButton x:Name="ServerRadio" Content="Server" HorizontalAlignment="Left" Margin="10,40,0,0" VerticalAlignment="Top"/>
                    </Grid>
                </GroupBox>
                <Label x:Name="CommandLabel" Content="_Command" HorizontalAlignment="Left" Height="25" Margin="10,0,0,8" VerticalAlignment="Bottom" Width="68" Target="{Binding ElementName=CommandTextBox, Mode=OneWay}"/>
                <TextBox x:Name="CommandTextBox" Margin="83,0,10,10" TextWrapping="Wrap" Height="23" VerticalAlignment="Bottom"/>
                <Button x:Name="StartIperfButton" Content="Start Iperf" HorizontalAlignment="Left" Margin="10,10,0,0" VerticalAlignment="Top" Width="75"/>
                <Button x:Name="StopIperfButton" Content="Stop Iperf" HorizontalAlignment="Left" Margin="10,35,0,0" VerticalAlignment="Top" Width="75"/>
                <Label x:Name="IpLabel" Content="IP" HorizontalAlignment="Left" Margin="100,10,0,0" Width="20" Target="{Binding ElementName=IpTextBox, Mode=OneWay}" Height="23" VerticalAlignment="Top"/>
                <TextBox x:Name="IpTextBox" HorizontalAlignment="Left" Margin="145,10,0,0" TextWrapping="Wrap" Width="97" Height="23" VerticalAlignment="Top"/>
                <Label x:Name="TimeLabel" Content="Time" HorizontalAlignment="Left" Margin="100,38,0,0" Width="40" Target="{Binding ElementName=TimeTextBox, Mode=OneWay}" Height="23" VerticalAlignment="Top"/>
                <TextBox x:Name="TimeTextBox" HorizontalAlignment="Left" Margin="145,38,0,0" TextWrapping="Wrap" Width="97" Height="23" VerticalAlignment="Top"/>
                <GroupBox x:Name="VersionGroupBox" Header="iPerf Version" Height="82" Margin="0,0,115,0" VerticalAlignment="Top" HorizontalAlignment="Right" Width="100">
                    <Grid Margin="0">
                        <RadioButton x:Name="Version2Radio" Content="Version 2" HorizontalAlignment="Left" Margin="10,10,0,0" VerticalAlignment="Top" IsChecked="True"/>
                        <RadioButton x:Name="Version3Radio" Content="Version 3" HorizontalAlignment="Left" Margin="10,40,0,0" VerticalAlignment="Top"/>
                    </Grid>
                </GroupBox>
            </Grid>
        </GroupBox>
        <GroupBox x:Name="AnalyzerGroupBox" Header="Analyzer" Height="85" Margin="10,230,10,0" VerticalAlignment="Top">
            <Grid Margin="0">
                <Button x:Name="StartAnalyzerButton" Content="Start Analyzer" HorizontalAlignment="Left" Margin="10,10,0,0" VerticalAlignment="Top" Width="85"/>
                <Button x:Name="StopAnalyzerButton" Content="Stop Analyzer" HorizontalAlignment="Left" Margin="10,35,0,0" VerticalAlignment="Top" Width="85"/>
                <Label x:Name="MaxScaleLabel" Content="Max Scale" HorizontalAlignment="Left" Height="23" Margin="100,10,0,0" VerticalAlignment="Top" Width="69" Target="{Binding ElementName=MaxScaleTextBox, Mode=OneWay}"/>
                <TextBox x:Name="MaxScaleTextBox" HorizontalAlignment="Left" Margin="174,10,0,0" TextWrapping="Wrap" Width="55" Height="23" VerticalAlignment="Top"/>
                <Label x:Name="LastXLabel" Content="Show Last" HorizontalAlignment="Left" Height="23" Margin="100,38,0,0" VerticalAlignment="Top" Width="69" Target="{Binding ElementName=LastXTextBox, Mode=OneWay}"/>
                <TextBox x:Name="LastXTextBox" HorizontalAlignment="Left" Margin="174,38,0,0" TextWrapping="Wrap" Width="55" Height="23" VerticalAlignment="Top"/>
                <CheckBox x:Name="MaxScaleCheckBox" Content="Auto" HorizontalAlignment="Left" Margin="234,16,0,0" VerticalAlignment="Top" IsChecked="True"/>
            </Grid>
        </GroupBox>
        <WindowsFormsHost x:Name="FormWfa" Margin="10,320,10,67"/>
    </Grid>
</Window>
"@
        
        $InputXml = $InputXml -replace 'mc:Ignorable="d"', '' -replace 'x:N', 'N' -replace '^<Win.*', '<Window'
                 
        [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
        [xml]$Xaml = $InputXml
        
        #Read XAML
        $XamlReader = (New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList $Xaml)
        try
        {
            $SyncHash.Form = [Windows.Markup.XamlReader]::Load( $XamlReader )
        }
        catch
        {
            $SyncHash.host.ui.WriteErrorLine('Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed.')
        }
        
        # Load XAML Objects In PowerShell
        $Xaml.SelectNodes('//*[@Name]') | ForEach-Object -Process {
            $SyncHash.Add($_.Name,$SyncHash.Form.FindName($_.Name))
            #Set-Variable -Name "WPF$($_.Name)" -Value $Form.FindName($_.Name)
        }
        
        #Get-Variable WPF*
        
        # Actually make the objects work
        # Create chart
        [void][reflection.assembly]::LoadWithPartialName('System.Windows.Forms')
        [void][Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms.DataVisualization')
        $SyncHash.Chart = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.Chart

        # Add chart area to chart
        $SyncHash.ChartArea = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.ChartArea
        $SyncHash.Chart.ChartAreas.Add($SyncHash.ChartArea)

        [void]$SyncHash.Chart.Series.Add('Bandwidth (Mbits/sec)')
        [void]$SyncHash.Chart.Series.Add('Transfer (MBytes)')

        # Display the chart on a form
        #$SyncHash.Chart.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        #$SyncHash.Chart.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (0, 100)
        $SyncHash.Chart.BackColor = [System.Drawing.Color]::Transparent
        $SyncHash.Chart.Series['Bandwidth (Mbits/sec)'].ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::'Line'
        $SyncHash.Chart.Series['Transfer (MBytes)'].ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::'Line'
        $SyncHash.Chart.Width = 800
        $SyncHash.ChartLegend = New-Object -TypeName System.Windows.Forms.DataVisualization.Charting.Legend
        [void]$SyncHash.Chart.Legends.Add($SyncHash.ChartLegend)

        $SyncHash.FormWfa.Child = $SyncHash.Chart
        #$SyncHash.Form.controls.add($SyncHash.Chart)
        #$SyncHash.Form.Invoke([action]{$SyncHash.Form.controls.add($SyncHash.Chart)})

        $SyncHash.StartIperfButton.Add_Click({
                Start-Iperf
        })
        
        $SyncHash.StopIperfButton.Add_Click({
                Stop-Iperf
        })

        $SyncHash.StartAnalyzerButton.Add_Click({
                Start-Analyzer
        })

        $SyncHash.StopAnalyzerButton.Add_Click({
                Stop-Analyzer
        })

        $SyncHash.IpTextBox.Text = '127.0.0.1'
        $SyncHash.TimeTextBox.Text = 60

        $SyncHash.IpTextBox.add_TextChanged({
                Set-IperfCommand
        })

        $SyncHash.TimeTextBox.add_TextChanged({
                Set-IperfCommand
        })

        $SyncHash.ClientRadio.add_Checked({
                Set-IperfCommand
        })

        $SyncHash.ServerRadio.add_Checked({
                Set-IperfCommand
        })

        $SyncHash.Version2Radio.add_Checked({
                Set-IperfCommand
        })

        $SyncHash.Version3Radio.add_Checked({
                Set-IperfCommand
        })

        # Csv SaveFileDialog
        $CsvSaveFileDialog = New-Object -TypeName System.Windows.Forms.SaveFileDialog
        $CsvSaveFileDialog.Filter = 'Comma Separated|*.csv|All files|*.*'
        $CsvSaveFileDialog.FileName = ([Environment]::GetFolderPath('Desktop') + '\iperf.csv')

        $SyncHash.CsvFilePathTextBox.Text = $CsvSaveFileDialog.FileName
        $SyncHash.CsvFilePathTextBox.add_TextChanged({
                Set-IperfCommand
        })

        $SyncHash.CsvFilePathButton.Add_Click({
                $CsvSaveFileDialog.ShowDialog()
                $SyncHash.CsvFilePathTextBox.Text = $CsvSaveFileDialog.FileName
        })

        $SyncHash.MaxScaleTextBox.IsEnabled = $false
        $SyncHash.MaxScaleTextBox.Text = 100
        $SyncHash.MaxScaleTextBox.add_TextChanged({
                $SyncHash.Chart.ChartAreas[0].Axisy.Maximum = $SyncHash.MaxScaleTextBox.Text
        })

        $SyncHash.MaxScaleCheckBox.add_Checked({
                $SyncHash.MaxScaleTextBox.IsEnabled = $false
                $SyncHash.Chart.ChartAreas[0].Axisy.Maximum = 'NaN'
        })

        $SyncHash.MaxScaleCheckBox.add_Unchecked({
                $SyncHash.MaxScaleTextBox.IsEnabled = $true
                $SyncHash.Chart.ChartAreas[0].Axisy.Maximum = $SyncHash.MaxScaleTextBox.Text
        })

        $SyncHash.LastXTextBox.Text = 0
        $SyncHash.LastXTextBox.add_TextChanged({

        })

        Set-IperfCommand

        Write-Status -Text 'PPerf Version 3.1' -Colore 'Blue'

        # Shows the form
        $null = $SyncHash.Form.ShowDialog()

        # Clean
        $SyncHash.host.ui.WriteVerboseLine('Stop-Iperf End')
        Stop-Iperf

        $SyncHash.host.ui.WriteVerboseLine('Stop-Analyzer End')
        Stop-Analyzer

        #$SyncHash.Error = $Error
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
