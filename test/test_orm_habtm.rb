require 'minitest/autorun'
require 'prism'
require 'tmpdir'

class OrmHabtmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('prism-habtm-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:students, %w[id name])
    @store.create_table(:courses, %w[id title])
    @store.create_table(:courses_students, %w[id course_id student_id])

    student_class = Class.new(Prism::Orm::Model) do
      table_name :students
      has_and_belongs_to_many :courses, class_name: 'Course', join_table: 'courses_students',
                                         foreign_key: 'student_id', association_foreign_key: 'course_id'
    end
    course_class = Class.new(Prism::Orm::Model) do
      table_name :courses
      has_and_belongs_to_many :students, class_name: 'Student', join_table: 'courses_students',
                                          foreign_key: 'course_id', association_foreign_key: 'student_id'
    end
    student_class.store = @store
    course_class.store = @store
    Object.const_set(:Student, student_class)
    Object.const_set(:Course, course_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[Student Course].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_adding_and_reading_from_both_sides
    alice = Student.create!(name: 'alice')
    bob = Student.create!(name: 'bob')
    math = Course.create!(title: 'math')
    physics = Course.create!(title: 'physics')

    alice.courses << math
    alice.courses << physics
    bob.courses << math

    assert_equal %w[math physics], alice.courses.map(&:title)
    assert_equal %w[math], bob.courses.map(&:title)
    assert_equal %w[alice bob], math.students.map(&:name).sort
    assert_equal %w[alice], physics.students.map(&:name)
  end

  def test_adding_twice_does_not_duplicate
    alice = Student.create!(name: 'alice')
    math = Course.create!(title: 'math')

    alice.courses << math
    alice.courses << math

    assert_equal 1, alice.courses.count
  end

  def test_delete_removes_association_without_touching_other_side
    alice = Student.create!(name: 'alice')
    math = Course.create!(title: 'math')
    alice.courses << math

    alice.courses.delete(math)

    assert_equal 0, alice.courses.count
    assert Student.find(alice.id) # student itself untouched
    assert Course.find(math.id) # course itself untouched
  end

  def test_replace_via_setter_swaps_full_set
    alice = Student.create!(name: 'alice')
    math = Course.create!(title: 'math')
    physics = Course.create!(title: 'physics')
    alice.courses << math

    alice.courses = [physics]

    assert_equal %w[physics], alice.courses.map(&:title)
  end
end
