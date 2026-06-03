require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "terms page renders without auth" do
    get terms_path
    assert_response :success
    assert_select "h1", /Terms of Service/
    assert_select "a[href=?]", privacy_path
  end

  test "privacy page renders without auth" do
    get privacy_path
    assert_response :success
    assert_select "h1", "Privacy Policy"
    assert_select "a[href=?]", terms_path
  end

  test "about page renders without auth" do
    get about_path
    assert_response :success
    assert_select "h1", "About Turf Totals"
    assert_select "a[href=?]", contact_path
  end

  test "contact page renders without auth" do
    get contact_path
    assert_response :success
    assert_select "h1", "Contact"
    assert_select "a[href=?]", about_path
  end

  test "global footer exposes the legitimacy + transparency links" do
    get terms_path
    assert_response :success
    # Footer is rendered in the application layout, so it appears on every
    # app page. These links are the site-legitimacy signals wallet scanners
    # look for; assert they are discoverable.
    %i[about_path contact_path privacy_path terms_path proof_of_reserves_path].each do |helper|
      assert_select "footer a[href=?]", send(helper), { minimum: 1 },
        "footer should link to #{helper}"
    end
  end
end
