require "test_helper"

# Regression — bug: off-board auth modal (fix-off-board-auth-modal).
#
# The navbar "Sign in" CTA opens the auth modal (modals/_auth) on EVERY page,
# but its Google + email buttons used to ONLY work when a contest board was
# mounted to catch their dispatched window events (auth-google-click /
# auth-magic-link-submit). On any non-board surface (homepage with no active
# contest, /contests index, /account, completed contests) both buttons were
# silent no-ops — hover worked, click did nothing, no console error.
#
# The modal now calls its own self-sufficient handlers, which dispatch to the
# board when present and otherwise run the auth action directly. This asserts the
# wiring at the render boundary; the click→popup / click→"Check your inbox"
# behaviour is covered end-to-end in e2e/auth_modal.spec.js.
class OffBoardAuthModalTest < ActionDispatch::IntegrationTest
  test "auth modal wires self-sufficient credential handlers on a non-board page" do
    get signin_path
    assert_response :success

    # Buttons call the modal's OWN methods (which fall back to running the auth
    # action when no contest board handles the dispatched event).
    assert_includes response.body, '@click="loginGoogle()"'
    assert_includes response.body, '@submit.prevent="submitMagicLink()"'

    # The old board-only wiring must be gone — otherwise the bug returns wherever
    # no selectionBoard() is mounted.
    assert_not_includes response.body,
      %q{$dispatch('auth-google-click', { ageAttested: true })}
    assert_not_includes response.body,
      %q{$dispatch('auth-magic-link-submit', { email: email, ageAttested: true })}
  end
end
