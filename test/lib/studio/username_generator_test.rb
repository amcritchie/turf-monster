require "test_helper"
require "minitest/mock"

# Turf Monster overrides studio-engine's Studio::UsernameGenerator
# (config/initializers/username_generator.rb) to emit
# "[adjective]-[fruit/veg/plant]" handles where BOTH parts are single words
# (e.g. "crispy-apple"). This guards that contract.
class Studio::UsernameGeneratorTest < ActiveSupport::TestCase
  test "build_name is adjective-noun with two single lowercase words" do
    100.times do
      name = Studio::UsernameGenerator.build_name
      parts = name.split("-")
      assert_equal 2, parts.size, "expected exactly two parts (no multi-word entries): #{name}"
      adjective, noun = parts
      assert_includes Studio::UsernameGenerator::ADJECTIVES, adjective, "#{adjective} not in ADJECTIVES"
      assert_includes Studio::UsernameGenerator::NOUNS, noun, "#{noun} not in NOUNS"
      assert_match(/\A[a-z]+-[a-z]+\z/, name)
    end
  end

  test "generated name satisfies the User username format + length validation" do
    name = Studio::UsernameGenerator.build_name
    assert_match(/\A[a-zA-Z0-9_-]+\z/, name)
    assert name.length.between?(3, 30), "#{name} (#{name.length}) must fit the 3..30 model limit"
  end

  test "word lists are single-word, lowercase, and sizeable" do
    assert_operator Studio::UsernameGenerator::ADJECTIVES.size, :>=, 120
    assert_operator Studio::UsernameGenerator::NOUNS.size, :>=, 120

    [Studio::UsernameGenerator::ADJECTIVES, Studio::UsernameGenerator::NOUNS].each do |list|
      assert_equal list, list.uniq, "word list must not contain duplicates"
      list.each { |word| assert_match(/\A[a-z]+\z/, word, "#{word.inspect} must be a single lowercase word") }
    end
  end

  test "generate appends a numeric suffix on collision to preserve uniqueness" do
    # Force build_name to always return a taken name, exhausting both retries,
    # so the numeric-suffix fallback path is exercised.
    user = users(:alex)
    taken = user.username
    Studio::UsernameGenerator.stub :build_name, taken do
      name = Studio::UsernameGenerator.generate
      assert_match(/\A#{Regexp.escape(taken)}-\d{4}\z/, name)
    end
  end

  test "generate returns a fresh name when no collision occurs" do
    name = Studio::UsernameGenerator.generate
    assert_not User.exists?(username: name)
    assert_match(/\A[a-z]+-[a-z]+(-\d{4})?\z/, name)
  end
end
