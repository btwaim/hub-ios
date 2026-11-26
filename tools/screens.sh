#!/bin/bash
# Startet die App im iPhone-Simulator im Vorführmodus und macht Screenshots (zum Prüfen von Layout und Dynamic Island).
set -x
pick() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
ios = [x for k, v in d.items() if 'iOS' in k for x in v]
pref = [x for x in ios if x['name'] in ('iPhone 17 Pro', 'iPhone 16 Pro', 'iPhone 15 Pro', 'iPhone 14 Pro')]
pro = [x for x in ios if x['name'].startswith('iPhone') and 'Pro' in x['name'] and 'Max' not in x['name']]
anyp = [x for x in ios if x['name'].startswith('iPhone')]
c = pref or pro or anyp
print(c[0]['udid'] + ' ' + c[0]['name'] if c else '')
"
}
read -r DEV NAME <<< "$(pick)"
echo "Simulator: $DEV $NAME"
[ -z "$DEV" ] && exit 1
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b
APP=$(find simbuild/Build/Products -name "Hub.app" -maxdepth 2 | head -1)
xcrun simctl install "$DEV" "$APP"
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 || true
mkdir -p screens
for s in home music player lyrics mp3 alarms map gaming; do
  xcrun simctl launch --terminate-running-process "$DEV" app.hubmusic.hub -demoScreen "$s"
  sleep 14
  xcrun simctl io "$DEV" screenshot "screens/$s.png"
done
# Ashen Oath (Spiel im Vorführmodus): kurz nach dem Start und mitten im Kampf
xcrun simctl launch --terminate-running-process "$DEV" app.hubmusic.hub -demoScreen game
sleep 16
xcrun simctl io "$DEV" screenshot screens/game.png
sleep 25
xcrun simctl io "$DEV" screenshot screens/game2.png
# Dynamic Island: Song „läuft“, dann App verlassen → Insel zeigt die Live-Aktivität
xcrun simctl launch --terminate-running-process "$DEV" app.hubmusic.hub -demoScreen player
sleep 12
xcrun simctl launch "$DEV" com.apple.Preferences
sleep 6
xcrun simctl io "$DEV" screenshot screens/island.png
ls -la screens
