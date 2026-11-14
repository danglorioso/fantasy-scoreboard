#!/bin/sh
set -e
: "${ESPN_LEAGUE_ID:?Set ESPN_LEAGUE_ID in the Xcode Cloud workflow}"
: "${ESPN_S2:?Set ESPN_S2 in the Xcode Cloud workflow}"
: "${ESPN_SWID:?Set ESPN_SWID in the Xcode Cloud workflow}"
cat > "$CI_PRIMARY_REPOSITORY_PATH/FantasyOverlay/Secrets.swift" <<SWIFT
enum Secrets {
    static let leagueID = "$ESPN_LEAGUE_ID"
    static let espnS2 = "$ESPN_S2"
    static let swid = "$ESPN_SWID"
}
SWIFT
echo "Secrets.swift written"
