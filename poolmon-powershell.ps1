<#

.SYNOPSIS
	.

.DESCRIPTION
	View kernel memory pool tag information

.PARAMETER tags
	comma separated list of tags to display

.PARAMETER values
	comma separated list of values to display

.PARAMETER sortvalue
	value to sort by

.PARAMETER sortdir
	direction to sort (ascending|descending)

.PARAMETER top
	top X records to display

.PARAMETER view
	output view (table|csv|grid)

.PARAMETER tagfile
	file containing tag information

.PARAMETER loop
	loop interval in seconds

.EXAMPLE
	.\poolmon-powershell.ps1 -tags FMfn -values DateTime,Tag,PagedUsedBytes,Binary,Description -tagfile pooltag.txt -loop 5 -view csv
	"DateTime","Tag","PagedUsedBytes","Binary","Description"
	"2019-07-24T12:21:57","FMfn","199922400","fltmgr.sys","NAME_CACHE_NODE structure"
	"2019-07-24T12:22:02","FMfn","199941136","fltmgr.sys","NAME_CACHE_NODE structure"
	"2019-07-24T12:22:07","FMfn","199878016","fltmgr.sys","NAME_CACHE_NODE structure"

#>
param (
	[string]$tags,
	[string]$values,
	[string]$sortvalue = 'TotalUsed',
	[string]$sortdir = 'Descending',
	[int]$top = 0,
	[string]$view = 'table',
	[string]$tagfile = 'pooltag.txt', #wanted tags
	[int]$loop = 0
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Win32 {
	public enum NT_STATUS
	{
		STATUS_SUCCESS = 0x00000000,
		STATUS_BUFFER_OVERFLOW = unchecked((int)0x80000005),
		STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004)
	}
	public enum SYSTEM_INFORMATION_CLASS
	{
		SystemPoolTagInformation = 22,
	}
	[StructLayout(LayoutKind.Sequential)]
	public struct SYSTEM_POOLTAG
	{
		[MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)] public byte[] Tag;
		public uint PagedAllocs;
		public uint PagedFrees;
		public System.IntPtr PagedUsed;
		public uint NonPagedAllocs;
		public uint NonPagedFrees;
		public System.IntPtr NonPagedUsed;
	}
	public class PInvoke {
		[DllImport("ntdll.dll")]
		public static extern NT_STATUS NtQuerySystemInformation(
		[In] SYSTEM_INFORMATION_CLASS SystemInformationClass,
		[In] System.IntPtr SystemInformation,
		[In] int SystemInformationLength,
		[Out] out int ReturnLength);
	}
}
'@
#*****************************************************************
#      best practice is to use strict mode
#*****************************************************************
Set-StrictMode -Version 3.0

#*****************************************************************
# * define the function
#*****************************************************************
<#
.DESCRIPTION "Get-Pool function"
#>
Function Get-Pool() {
	$tagFileHash = $null
	if ($tagfile) {
		if (Test-Path $tagfile) {
			$tagFileHash = New-Object System.Collections.Hashtable
			foreach ($line in Get-Content $tagfile) {
				if (($line.trim() -ne '') -and ($line.trim() -like '*-*-*') -and ($line.trim().SubString(0, 2) -ne '//') -and ($line.trim().SubString(0, 3) -ne 'rem')) {
					$t, $b, $d = $line.split('-')
					$t = $t.trim()
					$b = $b.trim()
					$d = $d.trim()
					if (!($tagFileHash.containsKey($t))) {
						$tagFileHash.Add($t, "$b|$d")
					}
				}
			}
		}
	}

	#set the initial pointer size to zero to force initial request to fail
	$bufSize, $bufLength = 0

	try {
		#fetch pool information from windows API
		while ($true) {
			[IntPtr]$bufptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufSize)
			$tagInfo = [Win32.PInvoke]::NtQuerySystemInformation([Win32.SYSTEM_INFORMATION_CLASS]::SystemPoolTagInformation, $bufptr, $bufSize, [ref]$bufLength)
			if ($tagInfo -eq [Win32.NT_STATUS]::STATUS_INFO_LENGTH_MISMATCH) {
				# as the amount of data is variable there is some negotiation from the API to find the correct buffer length
				[System.Runtime.InteropServices.Marshal]::FreeHGlobal($bufptr)		
				$bufSize = [System.Math]::Max($bufSize, $bufLength)
			} elseif ($tagInfo -eq [Win32.NT_STATUS]::STATUS_SUCCESS) {
				# correct buffer length has been found and data has been returned
				break
			} else {
				throw 'An error occurred getting SystemPoolTagInformation'
			}
		}

		$tags = $tags -Split ','
		$datetime = Get-Date
		$systemPoolTag = New-Object Win32.SYSTEM_POOLTAG
		$systemPoolTag = $systemPoolTag.GetType()
		$size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([Win32.SYSTEM_POOLTAG]))
		$offset = $bufptr.ToInt64()
		$count = [System.Runtime.InteropServices.Marshal]::ReadInt32($offset)
		$offset = $offset + [System.IntPtr]::Size
		for ($i = 0; $i -lt $count; $i++) {
			$entryPtr = New-Object System.Intptr -ArgumentList $offset
			$entry = [system.runtime.interopservices.marshal]::PtrToStructure($entryPtr, [type]$systemPoolTag)
			$tag = [System.Text.Encoding]::Default.GetString($entry.Tag)
			if (!$tags -or ($tags -and $tags -contains $tag)) {
				$tagResult = $null
				$tagResult = [PSCustomObject]@{
					DateTime          = Get-Date -Format s $datetime
					DateTimeUTC       = Get-Date -Format s $datetime.ToUniversalTime()
					Tag               = $tag
					PagedAllocs       = [int64]$entry.PagedAllocs
					PagedFrees        = [int64]$entry.PagedFrees
					PagedDiff         = [int64]$entry.PagedAllocs - [int64]$entry.PagedFrees
					PagedUsedBytes    = [int64]$entry.PagedUsed
					NonPagedAllocs    = [int64]$entry.NonPagedAllocs
					NonPagedFrees     = [int64]$entry.NonPagedFrees
					NonPagedDiff      = [int64]$entry.NonPagedAllocs - [int64]$entry.NonPagedFrees
					NonPagedUsedBytes = [int64]$entry.NonPagedUsed
					TotalUsedBytes    = [int64]$entry.PagedUsed + [int64]$entry.NonPagedUsed
				}
				if ($tagFileHash) {
					if ($tagFileHash.containsKey($tag)) {
						$Bin, $BinDesc = $tagFileHash.$tag.split('|')
						$tagResult | Add-Member NoteProperty 'Binary' $Bin
						$tagResult | Add-Member NoteProperty 'Description' $BinDesc
					} else {
						$tagResult | Add-Member NoteProperty 'Binary' ''
						$tagResult | Add-Member NoteProperty 'Description' ''
					}
				}
				#--- output the entry
				$tagResult
			}
			$offset = $offset + $size
		}
	} finally {
		#always free the buffer so as not to cause a memoryleak
		[System.Runtime.InteropServices.Marshal]::FreeHGlobal($bufptr)
	}
}

#*****************************************************************
# build the expression of the function
$expression = 'Get-Pool'
if ($sortvalue) {
	$expression += "|Sort-Object -Property $sortvalue"
	if ($sortdir -eq 'Descending') {
		$expression += ' -Descending'
	}
}
if ($top -gt 0) {
	$expression += "|Select-Object -First $top"
}
if ($values) {
	$expression += "|Select-Object $values"
}
if ($view -eq 'csv') {
	$expression += '|ConvertTo-Csv -NoTypeInformation'
} elseif ($view -eq 'grid') {
	$expression += '|Out-GridView -Title "Kernel Memory Pool (captured $(Get-Date -Format "dd/MM/yyyy HH:mm:ss"))" -Wait'
} elseif ($view -eq 'table') {
	$expression += '|Format-Table *'
}

#------------invoke the function
if ($loop -gt 0 -and $view -ne 'grid') {
	$loopcount = 0
	while ($true) {
		$loopcount++
		if ($loopcount -eq 1) {
			Invoke-Expression $expression
			if ($view -eq 'csv') {
				$expression += '|Select-Object -skip 1'
			}
		} else {
			Invoke-Expression $expression
		}
		Start-Sleep -Seconds $loop
	}
} else {
	Invoke-Expression $expression
}
