@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                        # interactive console tool
        'PSUseShouldProcessForStateChangingFunctions',  # New-WHFinding etc. build objects only
        'PSUseSingularNouns',
        'PSAvoidUsingPositionalParameters',
        'PSUseOutputTypeCorrectly',
        'PSReviewUnusedParameter'                       # false positives for params used in script blocks
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.4') }
    }
}
