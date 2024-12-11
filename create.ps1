#################################################
# HelloID-Conn-Prov-Target-NewBlack-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    $headers = @{
        'EVA-User-Agent' = 'HelloID/1.0.0'
        'Content-Type'   = 'application/json'
        Authorization    = "Bearer $($actionContext.Configuration.ApiKey)"
    }
    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        $splatSearchUser = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/message/SearchUsers"
            Method  = 'POST'
            Headers = $headers
            Body    = @{
                $correlationField = $correlationValue
                IncludeCustomers  = $false
                IncludeEmployees  = $true
            } | ConvertTo-Json
        }
        $responseSearchUser = (Invoke-WebRequest @splatSearchUser)
        $correlatedAccount = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes(($responseSearchUser.Content))) | ConvertFrom-Json).Result.Page
    }

    $actionList = [System.Collections.Generic.List[Object]]::new()
    if ($correlatedAccount.Count -eq 1) {
        $actionList.Add('CorrelateAccount')
        if (-not ($correlatedAccount.BackendRelationID -eq $actionContext.Data.BackendRelationID)) {
            $actionList.Add('UpdateBackendRelationID')
        }
    } elseif ($correlatedAccount.Count -gt 1) {
        throw "Multiple Accounts [$($correlatedAccount.Count)] found with Correlation Value [$correlationField : $correlationValue]"
    } else {
        # Check that the email is not already in use to prevent updating an existing account
        if (-not $null -eq $actionContext.Data.EmailAddress) {
            $bodyJson = @{
                EmailAddress     = $actionContext.Data.EmailAddress
                IncludeCustomers = $false
                IncludeEmployees = $true
            } | ConvertTo-Json

            $splatSearchUser = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/message/SearchUsers"
                Method  = 'POST'
                Headers = $headers
                Body    = ([System.Text.Encoding]::UTF8.GetBytes($bodyJson))
            }
            $responseSearchUser = (Invoke-WebRequest @splatSearchUser)

            if (-not ($null -eq $responseSearchUser.Content)) {
                $AccountWithSameEmail = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes(($responseSearchUser.Content))) | ConvertFrom-Json).Result.Page
            }
            if ($AccountWithSameEmail.Count -ge 1) {
                throw "There already is an account with email address [$($AccountWithSameEmail[0].EmailAddress)]: Account ID [$($AccountWithSameEmail[0].ID)] EmployeeNumber [$($AccountWithSameEmail[0].EmployeeNumber)]"
            }
        }
        $actionList.Add('CreateAccount')
        $actionList.Add('UpdateBackendRelationID')
    }

    # Process
    foreach ($action in $actionList) {
        switch ($action) {
            'CreateAccount' {
                $splatCreateParams = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/message/CreateEmployeeUser"
                    Method  = 'POST'
                    Body    = ([System.Text.Encoding]::UTF8.GetBytes(( $actionContext.Data | ConvertTo-Json)))
                    Headers = $headers
                }

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information 'Creating and correlating NewBlack account'
                    $createdAccountResult = Invoke-RestMethod @splatCreateParams

                    if ($createdAccountResult.Result -eq 2) {
                        Write-Warning "Warning: Intended to create account for employee number $($actionContext.Data.EmployeeNumber), but an existing account with user ID $($createdAccountResult.UserId) was updated instead."
                    }

                    $outputContext.AccountReference = $createdAccountResult.UserID
                } else {
                    Write-Information '[DryRun] Create and correlate NewBlack account, will be executed during enforcement'
                }
                $outputContext.Data = $actionContext.Data
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
                        IsError = $false
                    })

                break
            }

            'CorrelateAccount' {
                Write-Information 'Correlating NewBlack account'
                $outputContext.Data = $correlatedAccount
                $outputContext.AccountReference = $correlatedAccount.Id
                $outputContext.AccountCorrelated = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
                        IsError = $false
                    })
                break
            }

            'UpdateBackendRelationID' {
                Write-Information 'Update BackendRelationID NewBlack account'

                $splatUpdateParams = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/message/UpdateUser"
                    Method  = 'POST'
                    Body    = @{
                        ID                = $outputContext.AccountReference
                        BackendRelationID = $actionContext.Data.BackendRelationID
                    } | ConvertTo-Json
                    Headers = $headers
                }

                if (-not($actionContext.DryRun -eq $true)) {
                    $null = Invoke-RestMethod @splatUpdateParams

                } else {
                    Write-Information '[DryRun] Update BackendRelationID NewBlack account, will be executed during enforcement'
                }

                $outputContext.Data | Add-Member -MemberType NoteProperty -Name BackendRelationID -Value $actionContext.Data.BackendRelationID -Force
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update BackendRelationID [$($actionContext.Data.BackendRelationID)] NewBlack account"
                        IsError = $false
                    })
                break
            }
        }
    }
    $outputContext.Success = $true
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-NewBlackError -ErrorObject $ex
        $auditMessage = "Could not create or correlate NewBlack account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create or correlate NewBlack account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}