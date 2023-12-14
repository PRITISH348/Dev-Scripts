@echo off
setlocal EnableDelayedExpansion

set "server_path=C:\Users\Administrator\Documents\Code\Scripts"
set "siebel_path=C:\siebel\BIN"
set "log_path=C:\Users\Administrator\Documents\Code\Log"
set "username=SADMIN"
set "password=Welcome1"
set "hostname=trndbsrvr8.cubastion.net"
set "port=1521"
REM set "sid=SIEBELDB"
set "servicename=TRNDB49"
set "JiraId=%~1"
set "JiraStatus=%~2"
set "message=%JiraId% committed via Jenkins"

set "export_list_path=C:\Users\Administrator\Documents\Code\InputFiles"
set "GitBash=C:\Users\Administrator\Documents\Code\Git\bin\bash.exe"
set "FetchWSNameLog=%log_path%\%JiraId%_FetchWSName.log"
set "Siebel_export_success_status=Export Successful"
set "status=Submitted for Delivery"
set "GitBashPath=C:\Users\Administrator\Documents\Code\Git\bin"
set "DevMergeMessage=%JiraId% merged into DEV via Jenkins"
set "Dev_deployed_statusId=41"
set "Dev_failure_statusId=51"
set JiraIssueTypeFile="C:\Users\Administrator\Documents\Code\Log\%JiraId%_IssueType.txt"

if not "%JiraStatus%"=="Dev Deployment Approved" (
    set "CustomErrorCode=E-001"
    set "CustomErrorMessage=Incorrect Jira Status for DEV Deployment."
    goto ErrorHandling
)

REM Call the shell script to fetch parent Jira ID and download attachments
%GitBash% FetchJiraType.sh "%JiraId%"   REM Sub-task, New Feature

if not exist "!JiraIssueTypeFile!" (
    echo Error: Jira Issue Type Txt file does not exist.
)

REM Read the output from the file
set /p JiraIssueType=<"!JiraIssueTypeFile!"
echo JiraIssueType: !JiraIssueType!


if "!JiraIssueType!"=="Sub-task" (
 	set "Dev_deployed_statusId=141"
 	set "Dev_failure_statusId=171"
)

REM Call Shell Script to Fetch Siebel Workspace Name
REM 2^>^&1 means "redirect standard error to the same location as standard output."
if not !errorlevel! equ 0 (
    set "CustomErrorCode=E-002"
    set "CustomErrorMessage=Either Siebel Workspace doesn't exist or it is not in Submitted for Delivery status."
    REM Add error handling steps here
    goto ErrorHandling
)

set "merge_completed=0"

for /f "usebackq delims=" %%a in ("%FetchWSNameLog%") do (
    set "wsname=%%a"

    set "export_path=C:\Users\Administrator\Documents\Code\ExportedSIF\!wsname!"
    set "Input_path=%export_list_path%\!wsname!.txt"
    set "FetchWSStatusLog=%log_path%\!wsname!_FetchWSStatus.log"
    set "SiebelArchiveExportFile=%log_path%\!wsname!_ArchiveExport.log"
    set "ExportList=%log_path%\!wsname!_ExportList.log"

    REM Call shell script to create exportlist objects .sif
    "%GitBash%" ExportData.sh "%username%" "%password%" "%hostname%" "%port%" "%servicename%" "!wsname!" "%status%" > "!ExportList!" 2^>^&1
    if not !errorlevel! equ 0 (
        set "CustomErrorCode=E-003"
        set "CustomErrorMessage=Failed to create Siebel exportlist objects."
        REM Add error handling steps here
        goto ErrorHandling
    )

    REM Set Siebel Export Command
    set "siebdev_cmd=siebdev /c tools.cfg /d ServerDataSrc /u %username% /p %password% /ws !wsname! /batchexport "Siebel Repository" "!Input_path!" "!SiebelArchiveExportFile!""

    REM Check if the export directory exists and create it if it doesn't
    IF NOT EXIST "!export_path!" (
        mkdir "!export_path!"
    )

    REM Navigate to the BIN directory
    cd %siebel_path%

	echo  !siebdev_cmd!
    REM Run Siebel export command
    !siebdev_cmd!

    REM Check if the log file exists
    if not exist "!SiebelArchiveExportFile!" (
        set "CustomErrorCode=E-004"
        set "CustomErrorMessage=Siebel Archive Log file not found."
        REM Add error handling steps
        goto ErrorHandling
    )

    REM Read the log file and search for the success status
    set "export_successful=0"
    for /f "usebackq tokens=*" %%b in ("!SiebelArchiveExportFile!") do (
        echo %%b | findstr /C:"%Siebel_export_success_status%" >nul
        if not errorlevel 1 (
            set "export_successful=1"
        )
    )

    if not !export_successful! equ 1 (
        set "CustomErrorCode=E-004"
        set "CustomErrorMessage=Failed to export Siebel Workspace to Archive."
        goto ErrorHandling
    )

    REM SET Siebel Deliver Workspace command
    set "siebdev_deliver_cmd=siebdev /c tools.cfg /u %username% /p %password% /d ServerDataSrc /Deliverworkspace !wsname! %JiraId%"
    REM Navigate back to the BIN directory
    cd %siebel_path%

    REM Run Siebel Deliver command
    !siebdev_deliver_cmd!

    "%GitBash%" FetchWSStatus.sh %username% %password% %hostname% %port% %servicename% !wsname! > "!FetchWSStatusLog!" 2^>^&1
    if !errorlevel! neq 0 (
        set "CustomErrorCode=E-005"
        set "CustomErrorMessage=Failed to fetch Siebel Workspace Status."
        REM Add error handling steps here
        goto ErrorHandling
    )

    set /p wstatus=<!FetchWSStatusLog!
    if "!wstatus!"=="Delivered" (
        REM Call script to upload files to Bitbucket
        cd %server_path%
        call BitbucketUpload.bat "%JiraId%" "%message%" "!export_path!"
        if !errorlevel! neq 0 (
            set "CustomErrorCode=E-006"
            set "CustomErrorMessage=Failed to upload files to Bitbucket."
            REM Add error handling steps here
            goto ErrorHandling
        ) else (
			REM Merge the files into Bitbucket DEV Branch
			cd %server_path%
			call BitbucketUpload.bat "DEV" "%DevMergeMessage%" "!export_path!"
			if !errorlevel! neq 0 (
				set "CustomErrorCode=E-008"
				set "CustomErrorMessage=Failed to merge into DEV branch in Bitbucket."
				REM Add error handling steps here
				goto ErrorHandling
			) else ( 
					REM Remove the export folder
					IF EXIST "!export_path!" (
						rmdir /s /q "!export_path!"
					)
				)
		 )
    ) else (
        set "CustomErrorCode=E-007"
        set "CustomErrorMessage=Siebel Workspace couldn't be delivered, please check your Workspace for more information."
        goto ErrorHandling
    )

    echo Dev Deployment completed for workspace !wsname!.

    REM Clean up and prepare for the next iteration
    set "wsname="
    set "export_path="
    set "wstatus="
    set "FetchWSStatusLog="
    set "SiebelArchiveExportFile="
    set "ExportList="

    REM Set merge_completed=1 for each iteration
    set "merge_completed=1"
)

if !merge_completed! equ 1 (
    goto ExitLoop
)

:ExitLoop
REM Clean up and prepare for the final steps
set "wsname="
set "export_path="
set "wstatus="
set "FetchWSStatusLog="
set "SiebelArchiveExportFile="
set "ExportList="
cd %server_path%
call UpdateJiraStatus.bat "%JiraId%" "!Dev_deployed_statusId!"
if !errorlevel! neq 0 (
    set "CustomErrorCode=E-009"
    set "CustomErrorMessage=Failed to update Jira status to DEV Deployed."
    REM Add error handling steps here
    goto ErrorHandling
) else (
    goto Success
)

:Success
REM Add success handling steps here
set "successcomment=Code is successfully deployed to DEV via Jenkins."
REM Call Jira API to update comment in Jira
cd %server_path%
call UpdateJiraComment.bat "%JiraId%" "%successcomment%"
exit /b 0

:ErrorHandling
REM Add your error handling steps here
cd %server_path%
call UpdateJiraStatus.bat "%JiraId%" "!Dev_failure_statusId!"
REM Setting Comment for Failure
REM Setting Comment for Failure
set "failedComment=Error: !CustomErrorCode! - !CustomErrorMessage!"
REM Call Jira API to update comment in Jira
cd %server_path%
call UpdateJiraComment.bat "%JiraId%" "%failedComment%"
exit /b 1
