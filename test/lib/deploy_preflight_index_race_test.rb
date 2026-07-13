require "test_helper"
require "tmpdir"
require "open3"

# Regression guard for bin/deploy's working-tree preflight (task
# fix-deploy-preflight-index-race).
#
# THE BUG: bin/deploy gated the deploy on `git diff-index --quiet HEAD --` with NO
# preceding `git update-index --refresh`. On a freshly-prepared checkout — the
# release conductor's `_ship` worktree, (re)materialized at the frozen SHA and then
# bundle/asset/db-prepared right before the deploy, or a plain fresh clone — a tracked
# file's cached stat in the index goes stale (a byte-identical Gemfile.lock rewrite
# gives it a new inode/mtime; a fresh `git worktree add` writes files and index in the
# same clock-second → "racy git"). `git diff-index --quiet` trusts the stale stat and
# reports the file MODIFIED though its content is identical to HEAD, so bin/deploy
# aborted a legitimate production ship with "Working tree has uncommitted changes."
# (rel-20260713-4dc6a7 was blocked three times by this exact false positive.)
#
# THE FIX: `git update-index -q --refresh` immediately before the check re-hashes the
# stat-dirty entries, discovers the content is unchanged, and clears the false
# positive. A genuine content change stays dirty and is still caught. These tests
# prove that mechanism deterministically and assert bin/deploy uses it, in order.
class DeployPreflightIndexRaceTest < ActiveSupport::TestCase
  DEPLOY = Rails.root.join("bin", "deploy")

  # --- behavioral: the exact git mechanism the fix relies on -------------------
  test "stale index stat makes raw diff-index false-positive; --refresh clears it" do
    Dir.mktmpdir do |dir|
      run!(dir, "git", "init", "-q")
      run!(dir, "git", "config", "user.email", "t@t")
      run!(dir, "git", "config", "user.name", "t")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n")
      run!(dir, "git", "add", "Gemfile.lock")
      run!(dir, "git", "commit", "-q", "-m", "init")

      assert quiet_clean?(dir), "sanity: a freshly-committed tree must read clean"

      # Rewrite with IDENTICAL bytes (new inode + old mtime) → the index's cached stat
      # is now stale for a content-identical file, exactly like the conductor's prep.
      restage_identical(dir, "Gemfile.lock", "GEM\n  remote\n")
      assert_equal "GEM\n  remote\n", File.read(File.join(dir, "Gemfile.lock")), "content must be byte-identical"

      refute quiet_clean?(dir),
             "expected the un-refreshed diff-index to false-positive on a stat-stale but content-identical tree"

      system("git", "-C", dir, "update-index", "-q", "--refresh") # the fix
      assert quiet_clean?(dir),
             "after `git update-index -q --refresh` the content-identical tree must read clean"
    end
  end

  test "--refresh does NOT hide a genuine content change" do
    Dir.mktmpdir do |dir|
      run!(dir, "git", "init", "-q")
      run!(dir, "git", "config", "user.email", "t@t")
      run!(dir, "git", "config", "user.name", "t")
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n")
      run!(dir, "git", "add", "Gemfile.lock")
      run!(dir, "git", "commit", "-q", "-m", "init")

      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote\n  ACTUALLY CHANGED\n")
      system("git", "-C", dir, "update-index", "-q", "--refresh")
      refute quiet_clean?(dir),
             "a real content change must STILL read dirty after --refresh — the fix corrects staleness, it does not blank the check"
    end
  end

  # --- structural: bin/deploy adopts the refresh, in the right place -----------
  test "bin/deploy refreshes the index immediately before its dirty-tree check" do
    src = File.readlines(DEPLOY)
    diff_line    = src.index { |l| l =~ /git diff-index --quiet HEAD --/ }
    refresh_line = src.index { |l| l =~ /git update-index -q --refresh/ }

    assert diff_line, "bin/deploy must still gate the deploy on `git diff-index --quiet HEAD --`"
    assert refresh_line, "bin/deploy must refresh the index (`git update-index -q --refresh`) before that gate"
    assert refresh_line < diff_line,
           "the `git update-index --refresh` must come BEFORE `git diff-index --quiet HEAD --`, " \
           "or the racy false positive is not cleared"
    assert (diff_line - refresh_line) <= 3,
           "the refresh must sit immediately before the dirty-tree check (no unrelated work between them)"
  end

  private

  def quiet_clean?(dir)
    system("git", "-C", dir, "diff-index", "--quiet", "HEAD", "--")
  end

  def restage_identical(dir, name, content)
    path = File.join(dir, name)
    tmp = "#{path}.rewrite"
    File.write(tmp, content)
    File.rename(tmp, path)                # new inode → stat mismatch
    old = Time.utc(2000, 1, 1)
    File.utime(old, old, path)            # old mtime → guaranteed non-match, not racy
  end

  def run!(dir, *argv)
    out, status = Open3.capture2e(*argv, chdir: dir)
    assert status.success?, "command failed: #{argv.join(' ')}\n#{out}"
  end
end
