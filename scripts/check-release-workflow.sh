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

# A published release is never touched.
refusal = steps.find { |s| run_of.(s).include?('isDraft') }
ensure_that.(refusal && run_of.(refusal).include?('exit 1') && condition_of.(refusal).include?(TAG_GUARD),
             'a tag run must fail when the tag\'s release exists and is not a draft')

# The gate judges the result lines, not the exit code.
gate = steps.find { |s| run_of.(s).include?('scripts/check-test-run.sh') }
ensure_that.(gate, 'the gate must run scripts/check-test-run.sh')
if gate
  script = run_of.(gate)
  ensure_that.(script.include?('LOFTLINE_MIN_TESTS'), 'the gate must pass LOFTLINE_MIN_TESTS')
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

if errors.empty?
  puts 'workflow checks passed'
else
  errors.each { |message| warn "check-release-workflow: FAIL: #{message}" }
  exit 1
end
RUBY
