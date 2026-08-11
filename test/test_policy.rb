require 'minitest/autorun'
require 'prism'

PolicyTestUser = Struct.new(:id)
PolicyTestArticle = Struct.new(:id, :owner_id)

class PolicyTestArticlePolicy < Prism::Policy
  def edit?
    user && record.owner_id == user.id
  end
  alias_method :destroy?, :edit?
end

class PolicyTestArticlePolicy::Scope < Prism::Policy::Scope
  def resolve
    scope.select { |article| user && article.owner_id == user.id }
  end
end

class PolicyEmptyPolicy < Prism::Policy
end

class PolicyTest < Minitest::Test
  def setup
    @owner = PolicyTestUser.new(1)
    @stranger = PolicyTestUser.new(2)
    @article = PolicyTestArticle.new(10, 1)
  end

  def test_owner_may_edit_and_destroy
    policy = PolicyTestArticlePolicy.new(@owner, @article)
    assert policy.edit?
    assert policy.destroy?
  end

  def test_stranger_may_not_edit_or_destroy
    policy = PolicyTestArticlePolicy.new(@stranger, @article)
    refute policy.edit?
    refute policy.destroy?
  end

  def test_undeclared_query_default_denies
    policy = PolicyEmptyPolicy.new(@owner, @article)
    refute policy.publish?
    refute policy.archive?
  end

  def test_non_predicate_missing_method_still_raises
    policy = PolicyEmptyPolicy.new(@owner, @article)
    assert_raises(NoMethodError) { policy.some_method }
  end

  def test_for_record_resolves_the_conventional_policy_class
    assert_equal PolicyTestArticlePolicy, Prism::Policy.for_record(@article)
    assert_equal PolicyTestArticlePolicy, Prism::Policy.for_record(PolicyTestArticle)
  end

  def test_scope_resolves_to_only_the_users_own_records
    articles = [@article, PolicyTestArticle.new(11, 2)]
    resolved = PolicyTestArticlePolicy::Scope.new(@owner, articles).resolve
    assert_equal [@article], resolved
  end

  def test_scope_base_class_requires_resolve_to_be_implemented
    assert_raises(NotImplementedError) { Prism::Policy::Scope.new(@owner, []).resolve }
  end

  def test_not_authorized_error_carries_record_and_query
    error = Prism::Policy::NotAuthorizedError.new(@article, 'destroy?')
    assert_equal @article, error.record
    assert_equal 'destroy?', error.query
    assert_includes error.message, 'destroy?'
  end
end
