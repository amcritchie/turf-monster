require "test_helper"

# The legal-age attestation is flag-gated (AppFlags.age_attestation?,
# ENABLE_AGE_ATTESTATION) and parked OFF for the first contest. These tests
# pin the OFF state — the production default: no checkbox renders, signups
# succeed without the attestation param, and age_attested_at is NEVER
# stamped (a flag-off signup must not record an attestation the user was
# never shown). The ON state is covered by the per-flow controller tests,
# which enable the env var in their setup.
class AgeAttestationFlagTest < ActionDispatch::IntegrationTest
  test "flag defaults off in the test env" do
    assert_not AppFlags.age_attestation?
  end

  test "signin page renders no attestation checkbox when the flag is off" do
    get signin_path
    assert_response :success
    assert_no_match(/data-age-attestation/, response.body)
  end

  test "signin page renders the attestation checkbox when the flag is on" do
    ENV["ENABLE_AGE_ATTESTATION"] = "true"
    get signin_path
    assert_response :success
    assert_match(/data-age-attestation/, response.body)
  ensure
    ENV.delete("ENABLE_AGE_ATTESTATION")
  end

  test "engine signup succeeds without the attestation and stamps no age_attested_at" do
    assert_difference "User.count", 1 do
      post signup_path, params: { user: { email: "flagoff@mcritchie.studio" } }
    end
    assert_nil User.find_by(email: "flagoff@mcritchie.studio").age_attested_at,
               "flag-off signup must not fabricate an attestation timestamp"
  end

  test "magic-link signup succeeds without the attestation and stamps no age_attested_at" do
    token = Studio::Link.create_magic_link(email: "flagoff-ml@example.com", age_attested: false).token
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end
    assert_nil User.find_by(email: "flagoff-ml@example.com").age_attested_at
  end
end
