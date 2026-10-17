// Native Windows GUI Launcher for Orbit PC Companion.
// Compiled automatically by install_orbit.bat using Windows built-in csc.exe:
//   %SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /win32icon:orbit.ico /out:OrbitCompanion.exe OrbitCompanion.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Orbit PC Companion")]
[assembly: AssemblyDescription("Orbit PC Companion - System Tray Agent")]
[assembly: AssemblyCompany("Orbit")]
[assembly: AssemblyProduct("Orbit PC Companion")]
[assembly: AssemblyVersion("4.1.0.0")]
[assembly: AssemblyFileVersion("4.1.0.0")]

namespace OrbitCompanion
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "orbit_agent.py");
            string venvPythonw = Path.Combine(baseDir, ".venv", "Scripts", "pythonw.exe");
            string venvPython = Path.Combine(baseDir, ".venv", "Scripts", "python.exe");
            string installerBat = Path.Combine(baseDir, "install_orbit.bat");

            if (!File.Exists(scriptPath))
            {
                MessageBox.Show(
                    "Could not find orbit_agent.py in:\n" + baseDir,
                    "Orbit PC Companion",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return 1;
            }

            if (!File.Exists(venvPythonw) && !File.Exists(venvPython))
            {
                if (File.Exists(installerBat))
                {
                    ProcessStartInfo setupInfo = new ProcessStartInfo
                    {
                        FileName = installerBat,
                        WorkingDirectory = baseDir,
                        UseShellExecute = true
                    };
                    Process.Start(setupInfo);
                    return 0;
                }

                MessageBox.Show(
                    "Orbit Python environment (.venv) is not set up yet.\nPlease run install_orbit.bat first.",
                    "Orbit PC Companion",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
                return 1;
            }

            string pythonExe = File.Exists(venvPythonw) ? venvPythonw : venvPython;
            string joinedArgs = args.Length > 0 ? string.Join(" ", args) : "--tray";
            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = pythonExe,
                Arguments = "\"" + scriptPath + "\" " + joinedArgs,
                WorkingDirectory = baseDir,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            try
            {
                Process.Start(startInfo);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Could not start Orbit PC Companion:\n\n" + ex.Message,
                    "Orbit PC Companion",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return 1;
            }
        }
    }
}
