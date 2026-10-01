# Read-only inspection of a specifically named Windows Terminal window.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Title, [string] $ProjectPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
if (!('TerminalWindowInspection' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TerminalWindowInspection {
    public delegate bool Callback(IntPtr handle, IntPtr argument);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Callback callback, IntPtr argument);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr handle, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr handle);
    public static IntPtr[] Find(string title) {
        var result = new List<IntPtr>();
        EnumWindows((handle, argument) => {
            var text = new StringBuilder(1024);
            GetWindowText(handle, text, text.Capacity);
            if (IsWindowVisible(handle) && text.ToString() == title) result.Add(handle);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@
}
foreach ($handle in [TerminalWindowInspection]::Find($Title)) {
    $window = [Windows.Automation.AutomationElement]::FromHandle($handle)
    $paneCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
    $tabCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
    $panes = $window.FindAll([Windows.Automation.TreeScope]::Descendants, $paneCondition)
    $tabs = $window.FindAll([Windows.Automation.TreeScope]::Descendants, $tabCondition)
    $paneInfo = foreach ($pane in $panes) {
        $bounds = $pane.Current.BoundingRectangle
        $text = ($pane.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)).DocumentRange.GetText(12000)
        [pscustomobject]@{
            Title = $pane.Current.Name
            X = $bounds.X; Y = $bounds.Y; Width = $bounds.Width; Height = $bounds.Height
            HasProjectPath = if ($ProjectPath) { $text.Contains($ProjectPath) } else { $null }
            HasCodexUpdatePrompt = $text -match 'Update available.*0\.159'
            HasClaudeStartup = $text -match 'Claude Code v'
            HasStartupError = $text -match 'Set-PSReadLineOption:|Required command.*unavailable|is not recognized as'
        }
    }
    [pscustomobject]@{
        Handle = $handle.ToInt64(); Title = $Title
        Maximized = [TerminalWindowInspection]::IsZoomed($handle)
        Tabs = $tabs.Count; Panes = @($paneInfo)
    }
}
