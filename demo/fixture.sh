#!/bin/bash
# Creates a fake home with made-up Claude Code sessions, queues and usage for the demo (ISLAND_DEMO=1).
# Usage: demo/fixture.sh <dir>     then: ISLAND_DEMO=1 ISLAND_HOME=<dir> "build/Claude Island.app/Contents/MacOS/claude-island"
set -euo pipefail
H="${1:?usage: fixture.sh <dir>}"
rm -rf "$H"
S="$H/.claude/session-state"; Q="$H/.claude/island/queues"; N="$H/.claude/notifier/events"
mkdir -p "$S" "$Q" "$N" "$H/.claude-work" "$H/.claude-personal"
now=$(date +%s)

echo '{"oauthAccount":{"emailAddress":"alex@acme-studio.example"}}'  > "$H/.claude-work/.claude.json"
echo '{"oauthAccount":{"emailAddress":"alex@example.com"}}'          > "$H/.claude-personal/.claude.json"
cat > "$H/.claude/island/usage.json" <<JSON
{".claude-work":     {"plan":"Max 20x","limits":[["Session",38,170],["Week",61,3100]]},
 ".claude-personal": {"plan":"Pro",    "limits":[["Session",84,46],["Week",52,4300]]}}
JSON

# session <id> <status> <name> <account> <secondsAgo> <reason> <activity>
session() {
  printf '{"session_id":"%s","status":"%s","cwd":"/demo/%s","ts":%s,"tty":"","term":"zed","name":"%s","reason":"%s","account":"%s"}\n' \
    "$1" "$2" "$3" "$((now - $5))" "$3" "$6" "$4" > "$S/$1.json"
  [ -n "${7:-}" ] && echo "$7" > "$S/$1.activity"
  return 0
}
session storefront   working storefront   .claude-work     260 ""                                                  "Editing CheckoutSheet.tsx"
session api-gateway  working api-gateway  .claude-work     95  ""                                                  "Running the test suite"
session docs-site    waiting docs-site    .claude-work     40  "Which database should the migration target?"      ""
session mobile-app   waiting mobile-app   .claude-work     610 "Claude needs your permission to use Bash"          ""
session side-project working side-project .claude-personal 130 ""                                                  "Reading schema.prisma"

task() { printf '{"id":"%s","text":"%s","state":"%s","added":%s}' "$1" "$2" "$3" "$now"; }
cat > "$Q/storefront.json" <<JSON
{"sid":"storefront","cwd":"/demo/storefront","name":"storefront","profile":"verify","maxChain":3,"chain":1,"paused":false,
 "updated":$now,"tasks":[$(task t1 "Add Apple Pay to the checkout sheet" running),
 $(task t2 "Write end-to-end tests for the cart" queued),
 $(task t3 "Update the changelog and open a PR" queued)]}
JSON
