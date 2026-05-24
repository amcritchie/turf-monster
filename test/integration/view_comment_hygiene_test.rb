require "test_helper"

# Static lint that catches three real bugs that bit this app's modal
# system in the 2026-05-23 debug session. All three produce silent HTML
# parser recovery — the page renders WRONG without any error log,
# usually with content reparented into unrelated containers.
#
# What it checks:
#
# 1. HTML comments containing `--` (HTML5 forbids this — most common
#    offender is a CSS custom property mentioned in a dev note, e.g.
#    `<!-- ... --nav-h ... -->`). When the parser hits a forbidden `--`
#    inside a comment it enters error recovery; downstream sibling
#    elements can end up nested inside unrelated parents. Symptom we
#    saw: the contest's <div id="board"> appeared INSIDE a modal card's
#    `<p class="text-xs ...">` subtitle slot, producing 6 recursive
#    show.html.erb renders + 3 selectionBoard Alpine instances.
#
# 2. HTML comment opened with `<!--` but closed with `%>` (ERB
#    delimiter mistakenly used to close an HTML comment). The parser
#    keeps reading bytes looking for `-->`, mangles the surrounding
#    markup, then synthesizes phantom DOM elements with literal-string
#    attribute values like `x-show="null"`. Symptom: extra step div
#    visible OVER the modal's actual content; clicking nothing dismisses.
#
# 3. ERB comments `<%# ... %>` containing `%` characters. The ERB
#    compiler terminates the comment at the FIRST `%>`, NOT the
#    intended one — so everything after the first `%` becomes literal
#    HTML output. Symptom: bogus dev-note text rendered in the page,
#    usually inside an unrelated element.
#
# All three failure modes produce HTML that PARSES — no Ruby/Rails
# error — so they slip through every other test. This lint is the
# only thing that catches them.
#
# See memory: feedback-html-comment-double-hyphen, feedback-html-erb-
# comment-mixing, feedback-erb-comment-percent-close.
class ViewCommentHygieneTest < ActiveSupport::TestCase
  ERB_GLOB = Rails.root.join("app/views/**/*.erb")

  test "no HTML comments contain `--` (HTML5 forbidden)" do
    bad = []
    Dir[ERB_GLOB].each do |path|
      content = File.read(path)
      # Match the whole HTML comment span; check body for `--`.
      content.scan(/<!--(.*?)-->/m) do |body,|
        next unless body.include?("--")
        # Compute line number of the comment opener.
        offset = Regexp.last_match.pre_match.length
        line   = content[0..offset].count("\n") + 1
        preview = body.strip.gsub(/\s+/, " ")[0, 100]
        bad << "#{path.sub(Rails.root.to_s + '/', '')}:#{line}: contains `--` → #{preview.inspect}"
      end
    end
    assert bad.empty?, "HTML comments with `--` (browser will enter error recovery, can reparent DOM):\n  " + bad.join("\n  ")
  end

  test "no HTML comments closed with ERB `%>` instead of `-->`" do
    bad = []
    Dir[ERB_GLOB].each do |path|
      content = File.read(path)
      # Walk forward looking for any `<!--` that ISN'T followed by a `-->`
      # before the next `<!--` or end of file. If we find one and it
      # later closes with `%>`, that's the bug pattern.
      pos = 0
      while (open_idx = content.index("<!--", pos))
        # Find the next HTML closer or ERB closer
        html_close = content.index("-->", open_idx + 4)
        erb_close  = content.index("%>",  open_idx + 4)
        # If %> comes BEFORE --> (or --> doesn't exist), and the chunk
        # between open and %> doesn't itself contain a -->, it's a
        # mismatched open/close.
        if erb_close && (html_close.nil? || erb_close < html_close)
          line = content[0..open_idx].count("\n") + 1
          preview = content[open_idx, [erb_close - open_idx + 2, 120].min]
          bad << "#{path.sub(Rails.root.to_s + '/', '')}:#{line}: opened `<!--` closed `%>` → #{preview.inspect}"
          pos = erb_close + 2
        else
          pos = (html_close || content.length) + 3
        end
      end
    end
    assert bad.empty?, "HTML comments closed with ERB `%>` (parser enters error recovery, produces phantom DOM):\n  " + bad.join("\n  ")
  end

  test "no ERB comments `<%# %>` contain nested `<%` (likely premature termination)" do
    # `<%# ... %>` terminates at the FIRST `%>` after `<%#`. If a dev
    # writes a multi-line comment that mentions another ERB tag (e.g.
    # `<%%= yield %>` as a code example), the FIRST `%>` it contains
    # closes the comment early, and the rest of the intended comment
    # body becomes literal HTML output.
    #
    # We can't easily detect this via regex alone — the regex match IS
    # the early-terminated comment, so by definition `body` won't
    # contain a second `%>`. Instead we flag any ERB comment whose
    # captured body mentions `<%` (the start of another ERB tag).
    # That's a strong proxy for "the author wrote code-as-text inside
    # a comment", and even if not currently buggy, it's a maintenance
    # trap waiting for someone to extend it.
    bad = []
    Dir[ERB_GLOB].each do |path|
      content = File.read(path)
      content.scan(/<%#(.*?)%>/m) do |body,|
        # Match opener `<%` inside the comment body. Skip Rails partial
        # annotations like `<%# locals: ... %>` which are harmless.
        next unless body.include?("<%")
        offset = Regexp.last_match.pre_match.length
        line   = content[0..offset].count("\n") + 1
        preview = body.strip.gsub(/\s+/, " ")[0, 120]
        bad << "#{path.sub(Rails.root.to_s + '/', '')}:#{line}: ERB comment body contains `<%` → #{preview.inspect}"
      end
    end
    assert bad.empty?, "ERB comments with nested `<%` (terminates early at the inner `%>`, leaks the rest as literal HTML):\n  " + bad.join("\n  ")
  end
end
