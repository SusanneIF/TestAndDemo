$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Get-WorkItems.ps1'
. $scriptPath

function New-TestHttpResponse {
    param(
        [Parameter(Mandatory = $true)]$Body,
        [hashtable]$Headers = @{}
    )

    return [pscustomobject]@{
        Content = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        Headers = $Headers
    }
}

function Get-TestOctopusDeployment {
    param([string]$EnvironmentId)

    if ($EnvironmentId -eq 'prod-env') {
        return [pscustomobject]@{ Id = 'deploy-prod'; State = 'Success'; Created = '2026-01-01T12:00:00Z'; ReleaseId = 'release-prod' }
    }
    return [pscustomobject]@{ Id = 'deploy-atest'; State = 'Success'; Created = '2026-01-02T12:00:00Z'; ReleaseId = 'release-atest' }
}

function Get-TestApiResponse {
    param(
        [string]$Uri,
        [string]$WorkItemsMode = 'one',
        [string]$BuildMode = 'one',
        [switch]$Paginate
    )

    if ($Uri -match '/deployments\?') {
        if ($Paginate -and $Uri -match 'skip=0') {
            $deployments = @()
            for ($index = 0; $index -lt 100; $index++) {
                $deployments += [pscustomobject]@{ Id = "old-$index"; State = 'Failed'; Created = '2025-01-01T00:00:00Z'; ReleaseId = 'old-release' }
            }
            return New-TestHttpResponse @{ Items = $deployments }
        }
        $environmentId = if ($Uri -match 'environments=prod-env') { 'prod-env' } else { 'atest-env' }
        return New-TestHttpResponse @{ Items = @((Get-TestOctopusDeployment -EnvironmentId $environmentId)) }
    }
    if ($Uri -match '/releases/release-prod') {
        return New-TestHttpResponse @{ Version = '1.0.0' }
    }
    if ($Uri -match '/releases/release-atest') {
        return New-TestHttpResponse @{ Version = '2.0.0' }
    }
    if ($Uri -match '/_apis/build/builds\?') {
        if ($BuildMode -eq 'missing') {
            return New-TestHttpResponse @{ value = @() }
        }
        if ($BuildMode -eq 'ambiguous') {
            return New-TestHttpResponse @{ value = @(
                [pscustomobject]@{ Id = 101; BuildNumber = '1.0.0' }
                [pscustomobject]@{ Id = 102; BuildNumber = '1.0.0' }
            ) }
        }
        if ($Paginate -and $Uri -match 'buildNumber=1.0.0' -and $Uri -notmatch 'continuationToken') {
            return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = 99; BuildNumber = '1.0.0-extra' }) } @{ 'x-ms-continuationtoken' = 'build-page-2' }
        }
        $id = if ($Uri -match 'buildNumber=1.0.0') { 101 } else { 202 }
        if ($Paginate -and $Uri -match 'continuationToken=build-page-2') {
            return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = 101; BuildNumber = '1.0.0' }) }
        }
        return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = $id; BuildNumber = $(if ($id -eq 101) { '1.0.0' } else { '2.0.0' }) }) }
    }
    if ($Uri -match '/_apis/build/workitems\?') {
        if ($WorkItemsMode -eq 'empty') {
            return New-TestHttpResponse @{ value = @() }
        }
        if ($Paginate -and $Uri -notmatch 'continuationToken') {
            return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = 55 }) } @{ 'x-ms-continuationtoken' = 'workitems-page-2' }
        }
        if ($Paginate -and $Uri -match 'continuationToken=workitems-page-2') {
            return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = 56 }) }
        }
        return New-TestHttpResponse @{ value = @([pscustomobject]@{ Id = 55 }) }
    }
    if ($Uri -match '/_apis/wit/workitems/55\?') {
        return New-TestHttpResponse @{ fields = @{ 'System.Title' = 'A [linked] title (with markdown) `code`' } }
    }
    if ($Uri -match '/_apis/wit/workitems/56\?') {
        return New-TestHttpResponse @{ fields = @{ 'System.Title' = 'Second item' } }
    }

    throw "Unexpected test request: $Uri"
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $message = $null
    try {
        & $ScriptBlock
    }
    catch {
        $message = $_.Exception.Message
    }

    if ($null -eq $message) {
        throw "Expected an exception matching '$Pattern'."
    }
    if ($message -notlike $Pattern) {
        throw "Expected exception '$message' to match '$Pattern'."
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    if (-not $Text.Contains($Expected)) {
        throw "Expected text to contain '$Expected'."
    }
}

function Assert-Matches {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if (-not [Regex]::IsMatch($Text, $Pattern)) {
        throw "Expected text to match '$Pattern'."
    }
}

Describe 'Get-WorkItems release notes' {
    BeforeEach {
        $env:OCTOPUS_API_KEY = 'octopus-test-key'
        $env:AZDO_PAT = 'ado-test-pat'
        $script:CapturedUris = @()
        $script:CapturedAuthHeaders = @()
    }

    It 'uses exact build IDs and the required work-item query, and writes escaped linked Markdown' {
        Mock Invoke-WebRequest {
            $script:CapturedUris += $Uri
            $script:CapturedAuthHeaders += [pscustomobject]@{ Uri = $Uri; Headers = $Headers }
            Get-TestApiResponse -Uri $Uri
        }

        Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com/' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive

        Assert-Contains -Text ($script:CapturedUris -join "`n") -Expected 'https://dev.azure.com/org/project/_apis/build/workitems?fromBuildId=101&toBuildId=202&$top=200&api-version=5.1-preview.2'
        $report = Get-Content -LiteralPath (Join-Path $TestDrive '2.0.0.md') -Raw
        Assert-Matches -Text $report -Pattern '\[#55\]\(https://dev\.azure\.com/org/project/_workitems/edit/55\)'
        Assert-Contains -Text $report -Expected 'A \[linked\] title \(with markdown\) \`code\`'
        $octopusRequest = @($script:CapturedAuthHeaders | Where-Object { $_.Uri -match '/deployments\?' })[0]
        $adoRequest = @($script:CapturedAuthHeaders | Where-Object { $_.Uri -match '/_apis/build/builds\?' })[0]
        $octopusRequest.Headers['X-Octopus-ApiKey'] | Should Be 'octopus-test-key'
        $expectedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':ado-test-pat'))
        $adoRequest.Headers.Authorization | Should Be "Basic $expectedAuth"
    }

    It 'writes a helpful explanation when the build range has no work items' {
        Mock Invoke-WebRequest {
            Get-TestApiResponse -Uri $Uri -WorkItemsMode 'empty'
        }

        Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive

        Assert-Matches -Text (Get-Content -LiteralPath (Join-Path $TestDrive '2.0.0.md') -Raw) -Pattern 'No work items were associated with the build range from 1\.0\.0 to 2\.0\.0'
    }

    It 'rejects an ADO build with no exact build-number match' {
        Mock Invoke-WebRequest {
            Get-TestApiResponse -Uri $Uri -BuildMode 'missing'
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*No Azure DevOps build exactly matching release version*'
    }

    It 'rejects ambiguous exact ADO builds' {
        Mock Invoke-WebRequest {
            Get-TestApiResponse -Uri $Uri -BuildMode 'ambiguous'
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*Multiple Azure DevOps builds exactly match*'
    }

    It 'rejects an environment with no successful deployment' {
        Mock Invoke-WebRequest {
            if ($Uri -match 'environments=prod-env') {
                return New-TestHttpResponse @{ Items = @([pscustomobject]@{ Id = 'failed'; State = 'Failed'; Created = '2026-01-01T00:00:00Z'; ReleaseId = 'release-prod' }) }
            }
            Get-TestApiResponse -Uri $Uri
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } "*No successful deployment was found for environment 'prod-env'*"
    }

    It 'rejects equally recent successful deployments as ambiguous' {
        Mock Invoke-WebRequest {
            if ($Uri -match 'environments=prod-env') {
                return New-TestHttpResponse @{ Items = @(
                    [pscustomobject]@{ Id = 'first'; State = 'Success'; Created = '2026-01-01T12:00:00Z'; ReleaseId = 'release-prod' }
                    [pscustomobject]@{ Id = 'second'; State = 'Success'; Created = '2026-01-01T12:00:00Z'; ReleaseId = 'release-prod' }
                ) }
            }
            Get-TestApiResponse -Uri $Uri
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*share the latest timestamp*'
    }

    It 'fails clearly when either credential is missing' {
        Remove-Item Env:OCTOPUS_API_KEY
        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*OCTOPUS_API_KEY*'

        $env:OCTOPUS_API_KEY = 'octopus-test-key'
        Remove-Item Env:AZDO_PAT
        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*AZDO_PAT*'
    }

    It 'includes the endpoint and API failure detail in request errors' {
        Mock Invoke-WebRequest {
            throw 'Octopus refused the request'
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*GET https://octopus.example.com/api/Spaces-1/deployments*Octopus refused the request*'
    }

    It 'surfaces Azure DevOps API failures with the failing endpoint' {
        Mock Invoke-WebRequest {
            if ($Uri -match '/_apis/build/builds\?') {
                throw 'Azure DevOps denied the request'
            }
            Get-TestApiResponse -Uri $Uri
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*GET https://dev.azure.com/org/project/_apis/build/builds?buildNumber=1.0.0*Azure DevOps denied the request*'
    }

    It 'paginates Octopus deployments and ADO builds and work items' {
        Mock Invoke-WebRequest {
            $script:CapturedUris += $Uri
            Get-TestApiResponse -Uri $Uri -Paginate
        }

        Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive

        $captured = $script:CapturedUris -join "`n"
        Assert-Contains -Text $captured -Expected 'https://octopus.example.com/api/Spaces-1/deployments?projects=Projects-42&environments=prod-env&skip=100&take=100'
        Assert-Contains -Text $captured -Expected 'https://dev.azure.com/org/project/_apis/build/builds?buildNumber=1.0.0&api-version=7.1&continuationToken=build-page-2'
        Assert-Contains -Text $captured -Expected 'https://dev.azure.com/org/project/_apis/build/workitems?fromBuildId=101&toBuildId=202&$top=200&api-version=5.1-preview.2&continuationToken=workitems-page-2'
        Assert-Matches -Text (Get-Content -LiteralPath (Join-Path $TestDrive '2.0.0.md') -Raw) -Pattern 'Second item'
    }

    It 'rejects an unsafe release version before creating a filename' {
        Mock Invoke-WebRequest {
            if ($Uri -match '/releases/release-atest') {
                return New-TestHttpResponse @{ Version = '../escape' }
            }
            Get-TestApiResponse -Uri $Uri
        }

        Assert-ThrowsLike {
            Invoke-WorkItemReport -OctopusUrl 'https://octopus.example.com' -OctopusSpaceId 'Spaces-1' -OctopusProjectId 'Projects-42' -ProductionEnvironmentId 'prod-env' -AtestEnvironmentId 'atest-env' -AdoOrganization 'org' -AdoProject 'project' -OutputDirectory $TestDrive
        } '*not safe to use as a filename*'
    }
}
