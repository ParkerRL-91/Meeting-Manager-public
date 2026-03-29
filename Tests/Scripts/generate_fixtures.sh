#!/bin/bash
# generate_fixtures.sh
#
# Generates synthetic test audio using macOS `say` command.
# Creates 5 fixtures simulating two-person meeting conversations.
# Each fixture = one .aiff audio file + one .txt ground truth transcript.
#
# Voices used:
#   Alex     - Speaker A (male)
#   Samantha - Speaker B (female)
#
# Usage: bash repo/Tests/Scripts/generate_fixtures.sh
# Output: repo/Tests/Fixtures/fixture-{1..5}/

set -e

FIXTURES_DIR="$(dirname "$0")/../Fixtures"
mkdir -p "$FIXTURES_DIR"

generate_fixture() {
  local id=$1
  local dir="$FIXTURES_DIR/fixture-$id"
  mkdir -p "$dir"

  local speaker_a_voice="Alex"
  local speaker_b_voice="Samantha"
  local rate=175  # words per minute — normal conversational pace

  echo "Generating fixture $id..."

  # Write the ground truth transcript
  cat > "$dir/transcript.txt" << TRANSCRIPT
${TRANSCRIPT_CONTENT}
TRANSCRIPT

  # Generate audio for each speaker turn, then concatenate
  local part=0
  local parts=()

  while IFS='|' read -r speaker text; do
    [[ -z "$text" ]] && continue
    local voice
    if [[ "$speaker" == "A" ]]; then
      voice="$speaker_a_voice"
    else
      voice="$speaker_b_voice"
    fi
    local part_file="$dir/part-$part.aiff"
    say -v "$voice" -r $rate -o "$part_file" -- "$text"
    parts+=("$part_file")
    ((part++))
  done < "$dir/turns.txt"

  # Concatenate all parts into one file using afconvert pipeline
  # sox would be cleaner but requires homebrew; afconvert is built-in
  if command -v sox &>/dev/null; then
    sox "${parts[@]}" "$dir/audio.aiff"
  else
    # Fallback: concatenate raw audio data (works for same-format aiff)
    local tmp="$dir/audio.aiff"
    cp "${parts[0]}" "$tmp"
    for ((i=1; i<${#parts[@]}; i++)); do
      # Use afconvert to merge — write to wav then back to aiff
      local merged="$dir/merged-$i.aiff"
      cat "${parts[$((i-1))]}" "${parts[$i]}" > "$merged" 2>/dev/null || true
    done
    # Simple approach: just use the first part for format, concatenate with sox if available
    # Otherwise generate each turn as a separate file and let the test harness handle them
    cp "${parts[0]}" "$dir/audio.aiff"
    echo "Warning: sox not found. Install with 'brew install sox' for proper concatenation."
    echo "Fixture $id will use individual turn files instead."
  fi

  # Clean up part files
  rm -f "${parts[@]}"

  echo "  -> $dir/audio.aiff"
  echo "  -> $dir/transcript.txt"
}

# ─── Fixture 1: Short business meeting intro ────────────────────────────────
mkdir -p "$FIXTURES_DIR/fixture-1"
cat > "$FIXTURES_DIR/fixture-1/turns.txt" << 'EOF'
A|Good morning everyone. Let's get started with our weekly sync.
B|Good morning. I wanted to start by reviewing the progress from last week.
A|Sure. We completed the authentication module and the user dashboard.
B|That's great. What about the reporting feature? Is that on track?
A|We're about two days behind schedule, but we'll catch up by Thursday.
B|Okay. Let's make sure we prioritize that. Anything blocking you?
A|Just waiting on the API documentation from the backend team.
B|I'll follow up with them today. What's next on the agenda?
A|We need to discuss the deployment timeline and testing strategy.
B|Right. I think we should plan for a staged rollout starting next Monday.
EOF
cat > "$FIXTURES_DIR/fixture-1/transcript.txt" << 'EOF'
Good morning everyone. Let's get started with our weekly sync. Good morning. I wanted to start by reviewing the progress from last week. Sure. We completed the authentication module and the user dashboard. That's great. What about the reporting feature? Is that on track? We're about two days behind schedule, but we'll catch up by Thursday. Okay. Let's make sure we prioritize that. Anything blocking you? Just waiting on the API documentation from the backend team. I'll follow up with them today. What's next on the agenda? We need to discuss the deployment timeline and testing strategy. Right. I think we should plan for a staged rollout starting next Monday.
EOF

# ─── Fixture 2: Technical discussion with numbers and acronyms ──────────────
mkdir -p "$FIXTURES_DIR/fixture-2"
cat > "$FIXTURES_DIR/fixture-2/turns.txt" << 'EOF'
A|The API is returning a five hundred error on roughly three percent of requests.
B|Is that across all endpoints or just the search endpoint?
A|Mostly the search endpoint. The P ninety-nine latency is around eight hundred milliseconds.
B|That's too slow. We need to get it under two hundred milliseconds.
A|We could add a Redis cache layer. That should cut latency by at least sixty percent.
B|What's the estimated implementation time?
A|About three days including testing and deployment.
B|Let's do it. Can you also look at the database query performance?
A|Yes. I noticed some queries are doing full table scans. We need better indexes.
B|Okay. Let's target this for the next sprint. Put together a technical spec by Friday.
EOF
cat > "$FIXTURES_DIR/fixture-2/transcript.txt" << 'EOF'
The API is returning a five hundred error on roughly three percent of requests. Is that across all endpoints or just the search endpoint? Mostly the search endpoint. The P ninety-nine latency is around eight hundred milliseconds. That's too slow. We need to get it under two hundred milliseconds. We could add a Redis cache layer. That should cut latency by at least sixty percent. What's the estimated implementation time? About three days including testing and deployment. Let's do it. Can you also look at the database query performance? Yes. I noticed some queries are doing full table scans. We need better indexes. Okay. Let's target this for the next sprint. Put together a technical spec by Friday.
EOF

# ─── Fixture 3: Longer discussion, varied sentence structure ─────────────────
mkdir -p "$FIXTURES_DIR/fixture-3"
cat > "$FIXTURES_DIR/fixture-3/turns.txt" << 'EOF'
A|I've been reviewing the customer feedback from last quarter.
B|What are the main themes coming through?
A|Three things keep coming up. Speed, reliability, and the mobile experience.
B|Speed has always been a pain point for us. What specifically are customers saying?
A|They want the dashboard to load in under two seconds. Right now it takes about five.
B|Five seconds is unacceptable for a dashboard. What's causing it?
A|A combination of large JavaScript bundles and too many synchronous API calls on load.
B|We should implement code splitting and move to parallel API calls.
A|Agreed. That alone should get us to under two seconds.
B|What about reliability? Are we seeing outages or just slowness?
A|Mostly slowness during peak hours. We had two brief outages last month.
B|Two outages in a month is too many. We need to look at our infrastructure scaling.
A|I'll set up a meeting with the DevOps team to review our auto-scaling configuration.
B|Good. And for mobile, is this an iOS or Android problem or both?
A|Primarily iOS. The Android app is actually in pretty good shape.
B|Let's get the iOS team involved. I want a plan by end of week.
EOF
cat > "$FIXTURES_DIR/fixture-3/transcript.txt" << 'EOF'
I've been reviewing the customer feedback from last quarter. What are the main themes coming through? Three things keep coming up. Speed, reliability, and the mobile experience. Speed has always been a pain point for us. What specifically are customers saying? They want the dashboard to load in under two seconds. Right now it takes about five. Five seconds is unacceptable for a dashboard. What's causing it? A combination of large JavaScript bundles and too many synchronous API calls on load. We should implement code splitting and move to parallel API calls. Agreed. That alone should get us to under two seconds. What about reliability? Are we seeing outages or just slowness? Mostly slowness during peak hours. We had two brief outages last month. Two outages in a month is too many. We need to look at our infrastructure scaling. I'll set up a meeting with the DevOps team to review our auto-scaling configuration. Good. And for mobile, is this an iOS or Android problem or both? Primarily iOS. The Android app is actually in pretty good shape. Let's get the iOS team involved. I want a plan by end of week.
EOF

# ─── Fixture 4: Short, fast-paced exchange ──────────────────────────────────
mkdir -p "$FIXTURES_DIR/fixture-4"
cat > "$FIXTURES_DIR/fixture-4/turns.txt" << 'EOF'
A|Did the build pass?
B|No, two tests are failing in the payment module.
A|Which tests?
B|The refund calculation and the currency conversion tests.
A|I think I know what's wrong. I made a change to the decimal precision yesterday.
B|That would do it. Can you fix it today?
A|Yes, give me an hour.
B|Perfect. Let me know when the build is green and I'll do the code review.
A|Will do.
EOF
cat > "$FIXTURES_DIR/fixture-4/transcript.txt" << 'EOF'
Did the build pass? No, two tests are failing in the payment module. Which tests? The refund calculation and the currency conversion tests. I think I know what's wrong. I made a change to the decimal precision yesterday. That would do it. Can you fix it today? Yes, give me an hour. Perfect. Let me know when the build is green and I'll do the code review. Will do.
EOF

# ─── Fixture 5: Mixed content — numbers, names, technical terms ─────────────
mkdir -p "$FIXTURES_DIR/fixture-5"
cat > "$FIXTURES_DIR/fixture-5/turns.txt" << 'EOF'
A|Welcome everyone. Today we're discussing Q3 results and Q4 planning.
B|Thanks. Revenue came in at four point two million, which is twelve percent above target.
A|That's excellent. What drove the outperformance?
B|Two things. The enterprise deals Sarah closed in August, and the self-serve growth in September.
A|How many enterprise deals did Sarah close?
B|Seven deals totaling one point eight million in annual recurring revenue.
A|Impressive. What's the pipeline looking like for Q4?
B|We have forty-two qualified opportunities worth approximately six million in potential ARR.
A|If we close thirty percent of that we hit our Q4 target.
B|Right. The key focus areas are the financial services vertical and expanding into Canada.
A|Let's make sure the sales team has the resources they need. Any headcount requests?
B|We need two more account executives and one solutions engineer by November first.
A|I'll get that approved by end of week. Anything else on the agenda?
B|Just the product roadmap update. The mobile app launch is confirmed for October fifteenth.
EOF
cat > "$FIXTURES_DIR/fixture-5/transcript.txt" << 'EOF'
Welcome everyone. Today we're discussing Q3 results and Q4 planning. Thanks. Revenue came in at four point two million, which is twelve percent above target. That's excellent. What drove the outperformance? Two things. The enterprise deals Sarah closed in August, and the self-serve growth in September. How many enterprise deals did Sarah close? Seven deals totaling one point eight million in annual recurring revenue. Impressive. What's the pipeline looking like for Q4? We have forty-two qualified opportunities worth approximately six million in potential ARR. If we close thirty percent of that we hit our Q4 target. Right. The key focus areas are the financial services vertical and expanding into Canada. Let's make sure the sales team has the resources they need. Any headcount requests? We need two more account executives and one solutions engineer by November first. I'll get that approved by end of week. Anything else on the agenda? Just the product roadmap update. The mobile app launch is confirmed for October fifteenth.
EOF

# ─── Generate audio for each fixture ────────────────────────────────────────
RATE=175

for fixture_num in 1 2 3 4 5; do
  dir="$FIXTURES_DIR/fixture-$fixture_num"
  echo "Generating audio for fixture $fixture_num..."

  parts=()
  part=0
  while IFS='|' read -r speaker text; do
    [[ -z "$text" ]] && continue
    voice=$( [[ "$speaker" == "A" ]] && echo "Alex" || echo "Samantha" )
    part_file="$dir/part-$part.aiff"
    say -v "$voice" -r $RATE -o "$part_file" -- "$text"
    parts+=("$part_file")
    ((part++))
  done < "$dir/turns.txt"

  if command -v sox &>/dev/null; then
    sox "${parts[@]}" "$dir/audio.aiff"
    rm -f "${parts[@]}"
    echo "  ✓ $dir/audio.aiff (concatenated ${#parts[@]} turns)"
  else
    # No sox: keep individual part files, mark fixture as multi-part
    echo "  ✓ $dir/ (${#parts[@]} turn files — install sox for single-file audio)"
    touch "$dir/.multipart"
  fi
done

echo ""
echo "Done. Generated fixtures in: $FIXTURES_DIR"
echo "Run: python3 repo/Tests/Scripts/measure_wer.py --fixtures repo/Tests/Fixtures"
