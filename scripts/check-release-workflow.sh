#!/bin/zsh
# Structural check of .github/workflows/release.yml. The workflow cannot run before it is merged (a workflow_dispatch
# workflow must be on the default branch), so the properties that make a release safe are checked here, from the file:
# triggers and permissions, the version and channel rules, the test gate, signing without --deep, draft-first publishing
# that never overwrites a published release, and cleanup of the signing material.
# Usage: scripts/check-release-workflow.sh
set -euo pipefail
cd "${0:A:h}/.."
workflow=.github/workflows/release.yml
[[ -f $workflow ]] || { print -u2 -r -- "check-release-workflow: FAIL: $workflow is missing"; exit 1 }
exec ruby -ryaml - "$workflow" <<'RUBY'
path = ARGV.fetch(0)
workflow = YAML.load_file(path)
errors = []
ensure_that = ->(ok, message) { errors << message unless ok }

TAG_GUARD = "startsWith(github.ref, 'refs/tags/v')"

triggers = workflow['on'] || workflow[true] || {}
ensure_that.(triggers.keys.map(&:to_s).sort == %w[push workflow_dispatch], 'only push (tags) and workflow_dispatch may trigger a release')
ensure_that.(triggers.dig('push', 'tags') == ['v*'], 'push must trigger on tags: [v*] only')
ensure_that.(triggers.dig('workflow_dispatch', 'inputs', 'version', 'default').to_s == '0.0.0', 'workflow_dispatch needs a version input defaulting to 0.0.0')
ensure_that.(workflow['permissions'] == { 'contents' => 'write' }, 'permissions must be exactly contents: write')
concurrency = workflow['concurrency'] || {}
ensure_that.(concurrency['group'].to_s.include?('github.ref') && concurrency['cancel-in-progress'] == false,
             'a top-level concurrency group containing github.ref with cancel-in-progress: false is required')
ensure_that.(workflow.dig('env', 'LOFTLINE_MIN_TESTS').to_s.match?(/\A[0-9]+\z/), 'env LOFTLINE_MIN_TESTS must be a number')

job = (workflow['jobs'] || {})['build'] || {}
ensure_that.(job['runs-on'] == 'macos-15', 'the build job must run on macos-15')
ensure_that.(job.dig('env', 'HAS_SIGNING').to_s.include?('secrets.MACOS_CERTS_DEPLOY_KEY'), 'HAS_SIGNING must be a job-level env derived from the deploy key secret')
steps = job['steps'] || []
run_of = ->(step) { step['run'].to_s }
condition_of = ->(step) { step['if'].to_s }
named = ->(step) { step['name'] || step['uses'] || run_of.(step).lines.first.to_s.strip }

# Nothing from the event or the secrets is pasted into a script: they arrive through env, where they cannot be parsed as shell.
steps.each do |step|
  ensure_that.(!run_of.(step).include?('${{'), "step '#{named.(step)}' interpolates ${{ }} into a script; pass it through env")
end

ensure_that.(steps.first && steps.first['uses'].to_s.start_with?('actions/checkout') && steps.first.dig('with', 'fetch-depth') == 0,
             'the first step must be actions/checkout with fetch-depth: 0')

# Version and channel.
resolve = steps.find { |s| run_of.(s).include?('LOFTLINE_CHANNEL') && run_of.(s).include?('GITHUB_ENV') }
ensure_that.(resolve, 'a step must write LOFTLINE_VERSION and LOFTLINE_CHANNEL to GITHUB_ENV')
if resolve
  script = run_of.(resolve)
  ensure_that.(script.include?('^v[0-9]+\.[0-9]+\.[0-9]+$') && script.include?('exit 1'), 'a tag that is not vX.Y.Z must fail the job')
  ensure_that.(script.include?('channel=release') && script.include?('channel=rehearsal'), 'tag runs are channel release and dispatch runs rehearsal')
  ensure_that.(!script.include?('GITHUB_REF_NAME#') || script.include?('GITHUB_EVENT_NAME'), 'a dispatch run on a tag ref must not count as a release')
end

# A published release is never touched: checked when the run starts (so a doomed run fails in seconds) and again at
# the upload, because the draft can be published while the build runs.
state_steps = steps.each_index.select { |i| run_of.(steps[i]).include?('scripts/check-release-state.sh') }
ensure_that.(state_steps.size >= 2, 'scripts/check-release-state.sh must run twice: when the run starts and just before the upload')
state_steps.each do |i|
  ensure_that.(condition_of.(steps[i]).include?(TAG_GUARD), "step '#{named.(steps[i])}' must be guarded by #{TAG_GUARD}")
end
upload_index = steps.index { |s| run_of.(s).include?('gh release upload') }
gate_index = steps.index { |s| run_of.(s).include?('scripts/check-test-run.sh') }
ensure_that.(upload_index && state_steps.include?(upload_index), 'the step that uploads must itself check the release state first')
ensure_that.(state_steps.any? { |i| gate_index && i < gate_index }, 'the release state must also be checked before the gate runs')
if upload_index
  upload = run_of.(steps[upload_index])
  ensure_that.(upload.index('check-release-state.sh') && upload.index('gh release upload') && upload.index('check-release-state.sh') < upload.index('gh release upload'),
               'the state check must come before gh release upload in the upload step')
end

# The gate judges the result lines, not the exit code.
gate = steps.find { |s| run_of.(s).include?('scripts/check-test-run.sh') }
ensure_that.(gate, 'the gate must run scripts/check-test-run.sh')
if gate
  script = run_of.(gate)
  ensure_that.(script.include?('LOFTLINE_MIN_TESTS'), 'the gate must pass LOFTLINE_MIN_TESTS')
  ensure_that.(script.include?('Package.swift') && script.include?('testTarget'), 'the gate must count the test targets in Package.swift')
  ensure_that.(script.match?(/check-test-run\.sh [^\n]*"\$LOFTLINE_MIN_TESTS" "\$targets"/), 'the gate must pass that count to check-test-run.sh, so a target that printed nothing fails it')
  ensure_that.(script.include?('scripts/build.sh') && script.include?('scripts/test.sh') && script.include?('set +e'), 'the gate builds, then captures the test run with set +e')
  ensure_that.(script.include?('scripts/check-samples.sh') && !script.include?('--update'), 'the gate checks the samples without --update')
end

# Signing.
ensure_that.(steps.any? { |s| condition_of.(s).include?("HAS_SIGNING != 'true'") && run_of.(s).include?('exit 1') && condition_of.(s).include?("github.event_name == 'push'") },
             'a tag run without the signing secrets must fail loudly')
steps.each do |step|
  secret_use = step['env'].to_h.values.join(' ')
  next unless secret_use.match?(/secrets\.(MACOS_CERTS_DEPLOY_KEY|MACOS_CERT_PASSWORD|ASC_KEY_CONTENT)/)
  ensure_that.(condition_of.(step).include?("HAS_SIGNING == 'true'"), "step '#{named.(step)}' uses signing secrets without the HAS_SIGNING guard")
end
File.readlines(path).each_with_index do |line, index|
  next unless line.include?('--deep') && !line.strip.start_with?('#')
  ensure_that.(line.include?('--verify'), "line #{index + 1}: --deep is allowed only on a verification command: #{line.strip}")
end
bundle = steps.find { |s| run_of.(s).include?('scripts/bundle.sh') }
ensure_that.(bundle, 'the bundle must be assembled by scripts/bundle.sh (one assembler)')
if bundle
  ensure_that.(run_of.(bundle).include?('LOFTLINE_SIGN_IDENTITY'), 'bundle.sh needs LOFTLINE_SIGN_IDENTITY when signing')
  ensure_that.(run_of.(bundle).include?('LOFTLINE_VERSION') || bundle['env'].to_h.key?('LOFTLINE_VERSION') || workflow.to_s.include?('LOFTLINE_VERSION'), 'bundle.sh needs LOFTLINE_VERSION')
end
verify = steps.find { |s| run_of.(s).include?('codesign --verify --deep --strict') }
ensure_that.(verify, 'the signed bundle must be verified with codesign --verify --deep --strict')
if verify
  script = run_of.(verify)
  ensure_that.(script.include?('com.apple.security.app-sandbox'), 'verification must check the Quick Look extension kept its sandbox entitlement')
  ensure_that.(script.include?('runtime'), 'verification must check the hardened runtime flag')
  # The code requirement every update must satisfy is run against the real Developer ID build, so a typo in it fails the release
  # here and not every install in the field. It is printed by the helper itself, so there is one copy of the string.
  ensure_that.(script.include?('packaging/updater/macos.sh --print-requirement') && script.match?(/codesign --verify [^\n]*"-R=\$requirement" dist\/LoftLine\.app/),
               "verification must run the updater's code requirement (macos.sh --print-requirement) against dist/LoftLine.app with codesign --verify -R=")
end

# Notarisation.
notarise = steps.find { |s| run_of.(s).include?('notarytool submit') }
ensure_that.(notarise, 'a notarisation step is required')
if notarise
  script = run_of.(notarise)
  ensure_that.(script.include?('--wait') && script.include?('4XBH56T7RS') && script.include?('22e2fb14-d32b-4837-92b0-6280da32716d'), 'notarytool submit --wait with the checked-in key id and issuer')
  ensure_that.(script.include?('Accepted'), 'a notarisation that is not Accepted must fail')
  ensure_that.(script.include?('xcrun stapler staple') && script.include?('xcrun stapler validate') && script.include?('spctl --assess --type execute -v'), 'staple, validate and spctl are required')
  ensure_that.(script.include?('ditto -c -k --sequesterRsrc --keepParent'), 'the notarisation upload must be made with ditto -c -k --sequesterRsrc --keepParent')
  ensure_that.(condition_of.(notarise).include?("HAS_SIGNING == 'true'"), 'notarisation needs the HAS_SIGNING guard')
  # Apple's servers sometimes drop the connection (the v0.2.0 run died when `stapler validate` lost its link to CloudKit, after
  # the build had been Accepted). Stapling and its validation are retried; a notarisation that returned NO status is submitted
  # again, while a status that says Invalid is final and is never retried.
  ensure_that.(script.match?(/scripts\/retry\.sh \d+ \d+ xcrun stapler staple dist\/LoftLine\.app/) &&
               script.match?(/scripts\/retry\.sh \d+ \d+ xcrun stapler validate dist\/LoftLine\.app/),
               'stapling and its validation must go through scripts/retry.sh (Apple\'s servers drop connections)')
  ensure_that.(script.match?(/for attempt in 1 2 3.*?notarytool submit.*?\[ -n "\$status" \] && break/m),
               'notarytool submit must be retried only when it returned no status (a transport failure), never after Invalid')
end
ensure_that.(!workflow.to_s.match?(/ASC_KEY_ID.*secrets|secrets.*ASC_KEY_ID/), 'the key id and issuer are constants, not secrets')

# Smoke and packaging.
smoke = steps.index { |s| run_of.(s).include?('scripts/release-smoke.sh') }
stapled = steps.index { |s| run_of.(s).include?('xcrun stapler validate') }
ensure_that.(smoke && stapled && smoke > stapled, 'the smoke test runs on the notarised build, after stapling')
zip_name = steps.map { |s| run_of.(s) }.join("\n")[/ZIP_NAME=([^\s"]+)/, 1]
ensure_that.(zip_name == 'LoftLine-v$version-macos-arm64.zip', "the asset must be named LoftLine-vX.Y.Z-macos-arm64.zip, got #{zip_name.inspect}")
package = steps.find { |s| run_of.(s).include?('ditto -c -k --sequesterRsrc --keepParent') && run_of.(s).include?('"dist/$ZIP_NAME"') }
ensure_that.(package, 'the asset must be made with ditto -c -k --sequesterRsrc --keepParent')

# Publishing: draft first, tag runs only, rehearsals upload a short-lived artifact instead.
steps.each do |step|
  next unless run_of.(step).match?(/gh release (create|upload|edit|delete)/)
  ensure_that.(condition_of.(step).include?(TAG_GUARD), "step '#{named.(step)}' changes a release without the #{TAG_GUARD} guard")
end
run_text = steps.map { |s| run_of.(s) }.join("\n")
creates = run_text.scan(/^.*gh release create.*$/)
ensure_that.(!creates.empty? && creates.all? { |line| line.include?('--draft') }, 'a release is created with --draft')
ensure_that.(run_text.include?('gh release upload'), 'tag runs upload the zip to the release')
artifacts = steps.select { |s| s['uses'].to_s.start_with?('actions/upload-artifact') }
ensure_that.(artifacts.size == 1, 'exactly one upload-artifact step (the rehearsal artifact)')
artifacts.each do |step|
  ensure_that.(step.dig('with', 'retention-days') == 7, 'the rehearsal artifact is kept 7 days')
  ensure_that.(condition_of.(step).include?("LOFTLINE_CHANNEL == 'rehearsal'"), 'the artifact is uploaded for rehearsal runs only')
end

# Cleanup.
last = steps.last || {}
ensure_that.(condition_of.(last).include?('always()'), 'the last step must run with always()')
%w[certs AuthKey.p8 build.keychain].each do |item|
  ensure_that.(run_of.(last).include?(item), "cleanup must remove #{item}")
end

# A tag run needs the feed signing key too, so a missing secret fails the build at the start, not after a notarised draft exists.
ensure_that.(job.dig('env', 'HAS_UPDATE_KEY').to_s.include?('secrets.UPDATE_SIGN_KEY'), 'HAS_UPDATE_KEY must be a job-level env derived from the UPDATE_SIGN_KEY secret')
ensure_that.(steps.any? { |s| condition_of.(s).include?("HAS_UPDATE_KEY != 'true'") && condition_of.(s).include?("github.event_name == 'push'") && run_of.(s).include?('exit 1') },
             'a tag run without UPDATE_SIGN_KEY must fail at the start')

# The update feed: signed, uploaded to the DRAFT, downloaded again and verified exactly as a client sees it, and only then is the
# release published. A release is never "latest" before its feed exists and verifies.
feed = (workflow['jobs'] || {})['feed'] || {}
ensure_that.(!feed.empty?, 'a feed job is required')
unless feed.empty?
  ensure_that.(Array(feed['needs']) == ['build'], 'the feed job needs the build job and nothing else')
  ensure_that.(feed['runs-on'] == 'macos-15', 'the feed job runs on macos-15, where the scripts it calls (zsh, the system openssl) are the ones that are tested')
  feed_guard = feed['if'].to_s
  ensure_that.(feed_guard.include?("github.event_name == 'push'") && feed_guard.include?(TAG_GUARD),
               "the feed job must run only for a tag push (a dispatch run on a tag ref must never publish): if needs github.event_name == 'push' and #{TAG_GUARD}")
  feed_steps = feed['steps'] || []
  feed_steps.each do |step|
    ensure_that.(!run_of.(step).include?('${{'), "feed step '#{named.(step)}' interpolates ${{ }} into a script; pass it through env")
  end
  ensure_that.(feed_steps.first && feed_steps.first['uses'].to_s.start_with?('actions/checkout') && feed_steps.first.dig('with', 'fetch-depth') == 0,
               'the feed job must start with actions/checkout and fetch-depth: 0 (gcodeChanged compares tags)')
  text = feed_steps.map { |s| run_of.(s) }.join("\n")
  ensure_that.(feed_steps.any? { |s| s['env'].to_h['UPDATE_SIGN_KEY'].to_s.include?('secrets.UPDATE_SIGN_KEY') }, 'UPDATE_SIGN_KEY must reach the feed job through env')
  ensure_that.(text.include?('base64 -d') && text.match?(/RUNNER_TEMP[^\n]*update-signing\.dat|update-signing\.dat[^\n]*RUNNER_TEMP/),
               'the signing key is decoded into RUNNER_TEMP, never into the workspace')
  ensure_that.(text.include?('= draft'), 'the feed job must require the release to still be a draft')
  ensure_that.(!text.match?(/gh release (create|delete)/), 'the feed job must not create or delete a release')

  order = ['scripts/check-release-state.sh', 'gh release download', 'scripts/update-feed.sh', 'gh release upload', 'scripts/verify-feed.sh', 'gh release edit']
  positions = order.map { |needle| text.index(needle) }
  ensure_that.(positions.none?(&:nil?) && positions == positions.sort, "the feed job must run in this order: #{order.join(' → ')}")
  last_download = text.rindex('gh release download')
  ensure_that.(positions.none?(&:nil?) && last_download && last_download > positions[3] && last_download < positions[4],
               'the feed must be downloaded again from the draft release after it is uploaded and before it is verified')
  ensure_that.(text.match?(/gh release edit [^\n]*--draft=false/), 'publishing must be gh release edit --draft=false')
  ensure_that.(text.match?(/scripts\/update-feed\.sh/) && text.match?(/gh release upload [^\n]*latest\.json/), 'latest.json must be uploaded to the release')
  verify_args = text[/scripts\/verify-feed\.sh +(\S+)/, 1].to_s
  ensure_that.(!verify_args.empty? && !verify_args.start_with?('build/'), 'verification must read the re-downloaded files, not the build directory')
  ensure_that.(text.include?('packaging/updater/update-public-key.pub'), 'verification must use the committed public key')
  publish = feed_steps.find { |s| run_of.(s).include?('gh release edit') }
  ensure_that.(publish && run_of.(publish).include?('set -euo pipefail'), 'the publishing step must run under set -euo pipefail')
  if publish
    script = run_of.(publish)
    ensure_that.(script.index('scripts/verify-feed.sh') && script.index('scripts/verify-feed.sh') < script.index('gh release edit'),
                 'the step that publishes must verify the feed before gh release edit')
  end
  feed_last = feed_steps.last || {}
  ensure_that.(condition_of.(feed_last).include?('always()') && run_of.(feed_last).include?('update-signing.dat') && run_of.(feed_last).include?('RUNNER_TEMP'),
               'the last feed step must remove the decoded signing key with always()')
end

if errors.empty?
  puts 'workflow checks passed'
else
  errors.each { |message| warn "check-release-workflow: FAIL: #{message}" }
  exit 1
end
RUBY
