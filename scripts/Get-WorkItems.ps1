[CmdletBinding()]
param(
    [string]$OctopusUrl,
    [string]$OctopusSpaceId,
    [string]$OctopusProjectId,
    [string]$ProductionEnvironmentId,
    [string]$AtestEnvironmentId,
    [string]$AdoOrganization,
    [string]$AdoProject,
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'Polaris')
)

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-ResponseItems {
    param([Parameter(Mandatory = $true)]$Response)

    $itemsProperty = $Response.PSObject.Properties['Items']
    if ($null -eq $itemsProperty) {
        $itemsProperty = $Response.PSObject.Properties['value']
    }
    if ($null -eq $itemsProperty) {
        throw 'The API response did not contain an Items or value collection.'
    }

    return @($itemsProperty.Value)
}

function Get-ContinuationToken {
    param($Headers)

    if ($null -eq $Headers) {
        return $null
    }

    foreach ($key in $Headers.Keys) {
        if ([string]$key -ieq 'x-ms-continuationtoken') {
            return [string]$Headers[$key]
        }
    }

    return $null
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    try {
        $httpResponse = Invoke-WebRequest -Method Get -Uri $Uri -Headers $Headers -UseBasicParsing -ErrorAction Stop
        $body = ConvertFrom-Json -InputObject $httpResponse.Content -ErrorAction Stop
        return [pscustomobject]@{
            Body    = $body
            Headers = $httpResponse.Headers
        }
    }
    catch {
        throw "GET $Uri failed: $($_.Exception.Message)"
    }
}

function Get-OctopusDeployments {
    param(
        [Parameter(Mandatory = $true)][string]$OctopusBaseUrl,
        [Parameter(Mandatory = $true)][string]$SpaceId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$EnvironmentId,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $encodedSpaceId = [Uri]::EscapeDataString($SpaceId)
    $encodedProjectId = [Uri]::EscapeDataString($ProjectId)
    $encodedEnvironmentId = [Uri]::EscapeDataString($EnvironmentId)
    $pageSize = 100
    $skip = 0
    $deployments = @()

    do {
        $uri = "$OctopusBaseUrl/api/$encodedSpaceId/deployments?projects=$encodedProjectId&environments=$encodedEnvironmentId&skip=$skip&take=$pageSize"
        $response = Invoke-JsonGet -Uri $uri -Headers $Headers
        $page = Get-ResponseItems -Response $response.Body
        $deployments += $page
        $skip += $page.Count
    } while ($page.Count -eq $pageSize)

    return @($deployments)
}

function Get-LatestSuccessfulDeployment {
    param(
        [Parameter(Mandatory = $true)][object[]]$Deployments,
        [Parameter(Mandatory = $true)][string]$EnvironmentId
    )

    $successful = @($Deployments | Where-Object { $_.State -eq 'Success' })
    if ($successful.Count -eq 0) {
        throw "No successful deployment was found for environment '$EnvironmentId'."
    }

    foreach ($deployment in $successful) {
        if ([string]::IsNullOrWhiteSpace([string]$deployment.Created)) {
            throw "A successful deployment in environment '$EnvironmentId' has no Created timestamp."
        }
        try {
            $deployment | Add-Member -NotePropertyName ParsedCreated -NotePropertyValue ([DateTimeOffset]::Parse([string]$deployment.Created)) -Force
        }
        catch {
            throw "A successful deployment in environment '$EnvironmentId' has an invalid Created timestamp: '$($deployment.Created)'."
        }
    }

    $latestTime = ($successful | Measure-Object -Property ParsedCreated -Maximum).Maximum
    $latest = @($successful | Where-Object { $_.ParsedCreated -eq $latestTime })
    if ($latest.Count -gt 1) {
        throw "Multiple successful deployments share the latest timestamp in environment '$EnvironmentId'; refusing to choose an ambiguous release."
    }

    return $latest[0]
}

function Get-ReleaseVersion {
    param(
        [Parameter(Mandatory = $true)][string]$OctopusBaseUrl,
        [Parameter(Mandatory = $true)][string]$SpaceId,
        [Parameter(Mandatory = $true)]$Deployment,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    if ([string]::IsNullOrWhiteSpace([string]$Deployment.ReleaseId)) {
        throw "Deployment '$($Deployment.Id)' did not include a release ID."
    }

    $space = [Uri]::EscapeDataString($SpaceId)
    $releaseId = [Uri]::EscapeDataString([string]$Deployment.ReleaseId)
    $uri = "$OctopusBaseUrl/api/$space/releases/$releaseId"
    $response = Invoke-JsonGet -Uri $uri -Headers $Headers
    $version = [string](Get-ObjectPropertyValue -Object $response.Body -Name 'Version')
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Octopus release '$($Deployment.ReleaseId)' did not include a version."
    }

    return $version
}

function Get-AdoBuildsByNumber {
    param(
        [Parameter(Mandatory = $true)][string]$AdoBaseUrl,
        [Parameter(Mandatory = $true)][string]$BuildNumber,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $encodedBuildNumber = [Uri]::EscapeDataString($BuildNumber)
    $continuationToken = $null
    $builds = @()

    do {
        $uri = "$AdoBaseUrl/_apis/build/builds?buildNumber=$encodedBuildNumber&api-version=7.1"
        if (-not [string]::IsNullOrEmpty($continuationToken)) {
            $uri += '&continuationToken=' + [Uri]::EscapeDataString($continuationToken)
        }
        $response = Invoke-JsonGet -Uri $uri -Headers $Headers
        $builds += Get-ResponseItems -Response $response.Body
        $continuationToken = Get-ContinuationToken -Headers $response.Headers
    } while (-not [string]::IsNullOrEmpty($continuationToken))

    return @($builds | Where-Object { [string]$_.BuildNumber -ceq $BuildNumber })
}

function Resolve-AdoBuildId {
    param(
        [Parameter(Mandatory = $true)][string]$AdoBaseUrl,
        [Parameter(Mandatory = $true)][string]$BuildNumber,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $builds = @(Get-AdoBuildsByNumber -AdoBaseUrl $AdoBaseUrl -BuildNumber $BuildNumber -Headers $Headers)
    if ($builds.Count -eq 0) {
        throw "No Azure DevOps build exactly matching release version '$BuildNumber' was found."
    }
    if ($builds.Count -gt 1) {
        throw "Multiple Azure DevOps builds exactly match release version '$BuildNumber'; refusing to choose an ambiguous build."
    }

    return [string]$builds[0].Id
}

function Get-AdoBuildWorkItems {
    param(
        [Parameter(Mandatory = $true)][string]$AdoBaseUrl,
        [Parameter(Mandatory = $true)][string]$FromBuildId,
        [Parameter(Mandatory = $true)][string]$ToBuildId,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $continuationToken = $null
    $workItems = @()
    do {
        $uri = "$AdoBaseUrl/_apis/build/workitems?fromBuildId=$FromBuildId&toBuildId=$ToBuildId&`$top=200&api-version=5.1-preview.2"
        if (-not [string]::IsNullOrEmpty($continuationToken)) {
            $uri += '&continuationToken=' + [Uri]::EscapeDataString($continuationToken)
        }
        $response = Invoke-JsonGet -Uri $uri -Headers $Headers
        $workItems += Get-ResponseItems -Response $response.Body
        $continuationToken = Get-ContinuationToken -Headers $response.Headers
    } while (-not [string]::IsNullOrEmpty($continuationToken))

    return @($workItems)
}

function ConvertTo-MarkdownText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $singleLine = [Regex]::Replace($Text, '[\r\n]+', ' ').Trim()
    return [Regex]::Replace($singleLine, '([\\`*_{}\[\]()#+!|<>])', '\$1')
}

function Test-SafeVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '\A[A-Za-z0-9][A-Za-z0-9._+-]*\z' -or $Version.EndsWith('.')) {
        return $false
    }
    if ($Version -match '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        return $false
    }

    return $true
}

function Invoke-WorkItemReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OctopusUrl,
        [Parameter(Mandatory = $true)][string]$OctopusSpaceId,
        [Parameter(Mandatory = $true)][string]$OctopusProjectId,
        [Parameter(Mandatory = $true)][string]$ProductionEnvironmentId,
        [Parameter(Mandatory = $true)][string]$AtestEnvironmentId,
        [Parameter(Mandatory = $true)][string]$AdoOrganization,
        [Parameter(Mandatory = $true)][string]$AdoProject,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $octopusApiKey = [Environment]::GetEnvironmentVariable('OCTOPUS_API_KEY')
    $adoPat = [Environment]::GetEnvironmentVariable('AZDO_PAT')
    if ([string]::IsNullOrWhiteSpace($octopusApiKey)) {
        throw 'Missing required credential: set the OCTOPUS_API_KEY environment variable.'
    }
    if ([string]::IsNullOrWhiteSpace($adoPat)) {
        throw 'Missing required credential: set the AZDO_PAT environment variable.'
    }
    if ($OctopusUrl -notmatch '\Ahttps?://') {
        throw "OctopusUrl must be an absolute HTTP or HTTPS URL."
    }
    $requiredValues = @{
        OctopusSpaceId          = $OctopusSpaceId
        OctopusProjectId        = $OctopusProjectId
        ProductionEnvironmentId = $ProductionEnvironmentId
        AtestEnvironmentId      = $AtestEnvironmentId
        AdoOrganization         = $AdoOrganization
        AdoProject              = $AdoProject
    }
    foreach ($name in $requiredValues.Keys) {
        if ([string]::IsNullOrWhiteSpace($requiredValues[$name])) {
            throw "$name must not be empty."
        }
    }

    $octopusBaseUrl = $OctopusUrl.TrimEnd('/')
    $encodedOrganization = [Uri]::EscapeDataString($AdoOrganization)
    $encodedProject = [Uri]::EscapeDataString($AdoProject)
    $adoBaseUrl = "https://dev.azure.com/$encodedOrganization/$encodedProject"
    $octopusHeaders = @{ 'X-Octopus-ApiKey' = $octopusApiKey }
    $adoAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
    $adoHeaders = @{ Authorization = "Basic $adoAuth" }

    $productionDeployments = Get-OctopusDeployments -OctopusBaseUrl $octopusBaseUrl -SpaceId $OctopusSpaceId -ProjectId $OctopusProjectId -EnvironmentId $ProductionEnvironmentId -Headers $octopusHeaders
    $atestDeployments = Get-OctopusDeployments -OctopusBaseUrl $octopusBaseUrl -SpaceId $OctopusSpaceId -ProjectId $OctopusProjectId -EnvironmentId $AtestEnvironmentId -Headers $octopusHeaders
    $productionDeployment = Get-LatestSuccessfulDeployment -Deployments $productionDeployments -EnvironmentId $ProductionEnvironmentId
    $atestDeployment = Get-LatestSuccessfulDeployment -Deployments $atestDeployments -EnvironmentId $AtestEnvironmentId
    $productionVersion = Get-ReleaseVersion -OctopusBaseUrl $octopusBaseUrl -SpaceId $OctopusSpaceId -Deployment $productionDeployment -Headers $octopusHeaders
    $atestVersion = Get-ReleaseVersion -OctopusBaseUrl $octopusBaseUrl -SpaceId $OctopusSpaceId -Deployment $atestDeployment -Headers $octopusHeaders

    if (-not (Test-SafeVersion -Version $atestVersion)) {
        throw "ATEST release version '$atestVersion' is not safe to use as a filename."
    }

    $productionBuildId = Resolve-AdoBuildId -AdoBaseUrl $adoBaseUrl -BuildNumber $productionVersion -Headers $adoHeaders
    $atestBuildId = Resolve-AdoBuildId -AdoBaseUrl $adoBaseUrl -BuildNumber $atestVersion -Headers $adoHeaders
    $workItemRefs = Get-AdoBuildWorkItems -AdoBaseUrl $adoBaseUrl -FromBuildId $productionBuildId -ToBuildId $atestBuildId -Headers $adoHeaders

    $workItemDetails = @()
    foreach ($workItemRef in $workItemRefs) {
        $id = Get-ObjectPropertyValue -Object $workItemRef -Name 'Id'
        if ($null -eq $id) {
            $id = Get-ObjectPropertyValue -Object $workItemRef -Name 'id'
        }
        if ($null -eq $id -or [string]$id -notmatch '\A\d+\z') {
            throw 'Azure DevOps returned a work item reference without a numeric ID.'
        }

        $detailsUri = "$adoBaseUrl/_apis/wit/workitems/$id" + '?api-version=7.1'
        $detailsResponse = Invoke-JsonGet -Uri $detailsUri -Headers $adoHeaders
        $fields = Get-ObjectPropertyValue -Object $detailsResponse.Body -Name 'fields'
        $title = [string](Get-ObjectPropertyValue -Object $fields -Name 'System.Title')
        if ([string]::IsNullOrWhiteSpace($title)) {
            throw "Azure DevOps work item '$id' did not include a title."
        }

        $workItemDetails += [pscustomobject]@{ Id = [string]$id; Title = $title }
    }

    $escapedProductionVersion = ConvertTo-MarkdownText -Text $productionVersion
    $escapedAtestVersion = ConvertTo-MarkdownText -Text $atestVersion
    $markdown = @(
        "# Work items for ATEST release $escapedAtestVersion"
        ''
        "Production release: $escapedProductionVersion (build $productionBuildId)"
        "ATEST release: $escapedAtestVersion (build $atestBuildId)"
        ''
        'Work items between these builds:'
        ''
    )
    if ($workItemDetails.Count -eq 0) {
        $markdown += "No work items were associated with the build range from $escapedProductionVersion to $escapedAtestVersion."
        $markdown += ''
    }
    else {
        foreach ($workItem in $workItemDetails) {
            $escapedTitle = ConvertTo-MarkdownText -Text $workItem.Title
            $markdown += "- [#$($workItem.Id)](https://dev.azure.com/$encodedOrganization/$encodedProject/_workitems/edit/$($workItem.Id)) — $escapedTitle"
        }
        $markdown += ''
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
    }
    $outputPath = Join-Path $OutputDirectory "$atestVersion.md"
    [IO.File]::WriteAllText($outputPath, ($markdown -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output "Wrote release notes to $outputPath"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WorkItemReport -OctopusUrl $OctopusUrl -OctopusSpaceId $OctopusSpaceId -OctopusProjectId $OctopusProjectId -ProductionEnvironmentId $ProductionEnvironmentId -AtestEnvironmentId $AtestEnvironmentId -AdoOrganization $AdoOrganization -AdoProject $AdoProject -OutputDirectory $OutputDirectory
}
