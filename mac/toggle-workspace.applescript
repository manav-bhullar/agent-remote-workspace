-- Toggle Workspace: master ON/OFF switch for the remote workspace
-- (com.remoteworkspace.automount = reconnect checks, com.remoteworkspace.listener = doorbell)
--
-- Build as an app:  osacompile -o "Toggle Workspace.app" toggle-workspace.applescript

set uid to do shell script "id -u"
set agentDir to (POSIX path of (path to home folder)) & "Library/LaunchAgents/"
set labels to {"com.remoteworkspace.automount", "com.remoteworkspace.listener"}
set mountDir to "/Volumes/Codes"
set editorBundleId to "com.google.antigravity"

on isLoaded(lbl)
	try
		do shell script "launchctl list " & lbl
		return true
	on error
		return false
	end try
end isLoaded

on isMounted(dir)
	try
		do shell script "mount -t smbfs | awk '{print $3}' | grep -Fx " & quoted form of dir
		return true
	on error
		return false
	end try
end isMounted

-- 1. Honest status: count how many of the two background parts are running
set loadedCount to 0
repeat with l in labels
	if my isLoaded(contents of l) then set loadedCount to loadedCount + 1
end repeat

if loadedCount = 2 then
	set currentState to "ON"
	set btns to {"Cancel", "Turn OFF"}
else if loadedCount = 0 then
	set currentState to "OFF"
	set btns to {"Cancel", "Turn ON"}
else
	set currentState to "PARTLY ON (one background part is not running)"
	set btns to {"Cancel", "Turn OFF", "Turn ON"}
end if

set choice to button returned of (display dialog "Remote Workspace is currently " & currentState & "." buttons btns default button (last item of btns) cancel button "Cancel" with title "Workspace Status")

-- 2. Turn OFF: stop background parts, eject politely, force only if you agree
if choice is "Turn OFF" then
	set problems to {}
	set keptMounted to false

	repeat with l in labels
		try
			do shell script "launchctl bootout gui/" & uid & "/" & (contents of l)
		end try
	end repeat

	if my isMounted(mountDir) then
		try
			do shell script "diskutil unmount " & quoted form of mountDir
		end try
		if my isMounted(mountDir) then
			set ans to button returned of (display dialog "Some files in the shared folder are still in use (for example, open in your editor)." & return & return & "Save your work first. Force disconnect anyway?" buttons {"Keep Connected", "Force Disconnect"} default button "Keep Connected" with title "Workspace" with icon caution)
			if ans is "Force Disconnect" then
				try
					do shell script "diskutil unmount force " & quoted form of mountDir
				end try
				if my isMounted(mountDir) then set end of problems to "The shared folder could not be disconnected."
			else
				set keptMounted to true
			end if
		end if
	end if

	repeat with l in labels
		if my isLoaded(contents of l) then set end of problems to (contents of l) & " is still running."
	end repeat

	if problems is not {} then
		set AppleScript's text item delimiters to return
		display dialog "Workspace did not fully turn OFF:" & return & return & (problems as text) buttons {"OK"} default button "OK" with title "Workspace" with icon caution
	else if keptMounted then
		display dialog "Workspace is OFF." & return & return & "The shared folder stays connected, as you chose." buttons {"OK"} default button "OK" with title "Workspace OFF" giving up after 4
	else
		display dialog "Workspace is OFF." & return & return & "The shared folder is safely disconnected." buttons {"OK"} default button "OK" with title "Workspace OFF" giving up after 4
	end if

-- 3. Turn ON: start background parts, confirm, wait for the folder, open the editor
else if choice is "Turn ON" then
	set problems to {}

	repeat with l in labels
		if not my isLoaded(contents of l) then
			try
				do shell script "launchctl bootstrap gui/" & uid & " " & quoted form of (agentDir & (contents of l) & ".plist")
			end try
		end if
	end repeat

	repeat with l in labels
		if not my isLoaded(contents of l) then set end of problems to (contents of l) & " did not start."
	end repeat

	if problems is not {} then
		set AppleScript's text item delimiters to return
		display dialog "Workspace did not fully turn ON:" & return & return & (problems as text) buttons {"OK"} default button "OK" with title "Workspace" with icon caution
		return
	end if

	display notification "Background parts are on. Connecting to the server..." with title "Workspace ON"

	-- The reconnect check starts by itself (RunAtLoad); wait up to 30s for the share
	set ready to false
	repeat 30 times
		if my isMounted(mountDir) then
			set ready to true
			exit repeat
		end if
		delay 1
	end repeat

	if ready then
		try
			do shell script "open -b " & editorBundleId
		end try
		display dialog "Workspace is ON and connected." & return & return & "Opening your editor..." buttons {"OK"} default button "OK" with title "Workspace ON" giving up after 4
	else
		display dialog "Workspace is ON, but the shared folder has not connected yet." & return & return & "Is the server on? It will connect by itself as soon as the server is reachable." buttons {"OK"} default button "OK" with title "Workspace"
	end if
end if
