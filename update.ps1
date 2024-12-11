#################################################
# HelloID-Conn-Prov-Target-NewBlack-Update
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Configuration
$employeeProperties = @('EmployeeNumber', 'Function')

#region functions
function Resolve-NewBlackError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.Error.Message
        } catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }
    Write-Information 'Verifying if a NewBlack account exists'

    $headers = @{
        'EVA-User-Agent' = 'HelloID/1.0.0'
        'Content-Type'   = 'application/json'
        'Accept'         = 'application/json;charset=utf-8'
        Authorization    = "Bearer $($actionContext.Configuration.ApiKey)"
    }

    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/message/GetUser"
        Method  = 'POST'
        Headers = $headers
        Body    = @{
            ID = $actionContext.References.Account
        } | ConvertTo-Json
    }

    $responseGetUser = (Invoke-WebRequest @splatGetUser)
    $correlatedAccount = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes(($responseGetUser.Content))) | ConvertFrom-Json)

    $actionList = [System.Collections.Generic.List[Object]]::new()
    if ($correlatedAccount) {

        if ($correlatedAccount.SingleSignOnOnly -eq $true) {
            $correlatedAccount | Add-Member -MemberType NoteProperty -Name 'isSingleSignOnOnly' -Value "true"
        } else {
            $correlatedAccount | Add-Member -MemberType NoteProperty -Name 'isSingleSignOnOnly' -Value "false"
        }
        $correlatedAccount.PSObject.Properties.Remove('SingleSignOnOnly')

        #collect 'EmployeeNumber' 'function' info for account
        $splatGetEmployee = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/message/GetEmployeeData"
            Method  = 'POST'
            Headers = $headers
            Body    = @{
                UserID = $actionContext.References.Account
            } | ConvertTo-Json
        }
        $responseEmployee = (Invoke-WebRequest @splatGetEmployee)
        $correlatedEmployee = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes(($responseEmployee.Content))) | ConvertFrom-Json)
        if ($correlatedEmployee) {
            $correlatedAccount | Add-Member -MemberType NoteProperty -Name 'Function' -Value $correlatedEmployee.Function
            $correlatedAccount | Add-Member -MemberType NoteProperty -Name 'EmployeeNumber' -Value $correlatedEmployee.EmployeeNumber
        }

        $outputContext.PreviousData = $correlatedAccount

        $AccountObject = [PSCustomObject] @{}
        foreach ($property in  $actionContext.Data.PSObject.Properties) {
            $AccountObject | Add-Member -MemberType NoteProperty -Name $($property.Name) -Value $correlatedAccount.$($property.Name)
        }

        $splatCompareProperties = @{
            ReferenceObject  = @($AccountObject.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $PropertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }

        if ($propertiesChanged) {

            $userPropertiesChanged = $PropertiesChanged | Where-Object { $_.Name -notin $employeeProperties }
            if ($userPropertiesChanged) {
                $actionList.add('UpdateUser')
            }

            $employeePropertiesChanged = $PropertiesChanged | Where-Object { $_.Name -in $employeeProperties }
            if ($employeePropertiesChanged) {
                $actionList.add('UpdateEmployee')
            }
        } else {
            $actionList.add('NoChanges')
        }
    } else {
        $action = $actionList.add('NotFound')
    }

    # Process
    foreach ($action in $actionList) {
        switch ($action) {
            'UpdateUser' {
                Write-Information "Account user property(s) required to update: $($userPropertiesChanged.Name -join ', ')"

                # Make sure to test with special characters and if needed; add utf8 encoding.
                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating NewBlack user account with accountReference: [$($actionContext.References.Account)]"

                    $body = [PSCustomObject]  @{
                        ID = $actionContext.References.Account
                    }
                    foreach ($property in $userPropertiesChanged) {
                        $body | Add-Member -MemberType NoteProperty -Name $($property.Name) -Value $actionContext.Data.$($property.Name)
                    }

                    $bodyJson = $body | ConvertTo-Json
                    $splatUpdate = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/message/UpdateUser"
                        Method  = 'POST'
                        Headers = $headers
                        Body    = ([System.Text.Encoding]::UTF8.GetBytes($bodyJson))
                    }
                    $null = (Invoke-RestMethod @splatUpdate)

                } else {
                    Write-Information "[DryRun] Update NewBlack user account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update account was successful, user Account property(s) updated: [$($userPropertiesChanged.name -join ',')]"
                        IsError = $false
                    })
                break
            }
            'UpdateEmployee' {
                Write-Information "Account employee property(s) required to update: $($employeePropertiesChanged.Name -join ', ')"

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating NewBlack employee account with accountReference: [$($actionContext.References.Account)]"

                    $Body = [PSCustomObject]  @{
                        UserID = $actionContext.References.Account
                    }
                    foreach ($property in $employeePropertiesChanged) {
                        $Body | Add-Member -MemberType NoteProperty -Name $($property.Name) -Value $actionContext.Data.$($property.Name)
                    }
                    $bodyJson = $body | ConvertTo-Json
                    $splatUpdate = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/message/CreateOrUpdateEmployeeData"
                        Method  = 'POST'
                        Headers = $headers
                        Body    = ([System.Text.Encoding]::UTF8.GetBytes($bodyJson))
                    }
                    $null = (Invoke-RestMethod @splatUpdate)

                } else {
                    Write-Information "[DryRun] Update NewBlack employee account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update account was successful, employee account property(s) updated: [$($employeePropertiesChanged.name -join ',')]"
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Information "No changes to NewBlack account with accountReference: [$($actionContext.References.Account)]"

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                Write-Information "NewBlack account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                $outputContext.Success = $false
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "NewBlack account with accountReference: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NewBlackError -ErrorObject $ex
        $auditMessage = "Could not update NewBlack account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update NewBlack account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
