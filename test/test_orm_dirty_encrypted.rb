require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmDirtyEncryptedTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-dirty-encrypted-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:patients, %w[id name ssn notes])
    Facet::Orm::Encryption.primary_key = 'test-primary-key-do-not-use-in-prod'

    patient_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :ssn, deterministic: true
      encrypts :notes
    end
    patient_class.store = @store
    Object.const_set(:DirtyEncryptedPatient, patient_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Facet::Orm::Encryption.primary_key = nil
    Object.send(:remove_const, :DirtyEncryptedPatient) if Object.const_defined?(:DirtyEncryptedPatient)
  end

  def test_new_record_reports_plaintext_not_ciphertext_in_changes
    patient = DirtyEncryptedPatient.new(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    old_value, new_value = patient.changes['ssn']
    assert_nil old_value
    assert_equal '123-45-6789', new_value
    refute_includes patient.changes['ssn'].to_s, patient['ssn'].to_s
  end

  def test_changed_attributes_reports_plaintext_old_value
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'old note')
    patient.notes = 'new note'
    assert_equal 'old note', patient.changed_attributes['notes']
  end

  def test_attribute_was_and_attribute_change_report_plaintext_on_deterministic_column
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'n')
    patient.ssn = '999-99-9999'
    assert_equal '123-45-6789', patient.attribute_was('ssn')
    assert_equal ['123-45-6789', '999-99-9999'], patient.attribute_change('ssn')
  end

  def test_attribute_was_and_attribute_change_report_plaintext_on_nondeterministic_column
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'old note')
    patient.notes = 'new note'
    assert_equal 'old note', patient.attribute_was('notes')
    assert_equal ['old note', 'new note'], patient.attribute_change('notes')
  end

  def test_reassigning_the_same_plaintext_on_a_nondeterministic_column_is_not_dirty
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'same note')
    raw_before = patient['notes']
    patient.notes = 'same note'
    refute patient.attribute_changed?('notes'), 'assigning the value already held must not be dirty'
    refute patient.changed?
    assert_equal raw_before, patient['notes'], 'a true no-op must not even rewrite the ciphertext'
  end

  def test_reassigning_the_same_plaintext_on_a_deterministic_column_is_not_dirty
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'n')
    patient.ssn = '123-45-6789'
    refute patient.attribute_changed?('ssn')
    refute patient.changed?
  end

  def test_saved_changes_after_create_reports_plaintext
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    assert_equal [nil, '123-45-6789'], patient.saved_changes['ssn']
    assert_equal [nil, 'note'], patient.saved_changes['notes']
  end

  def test_saved_changes_after_update_reports_plaintext_and_only_the_real_change
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'old note')
    patient.update!(notes: 'new note')
    assert_equal ['old note', 'new note'], patient.saved_changes['notes']
    refute_includes patient.saved_changes.keys, 'ssn'
  end

  def test_restore_attributes_still_reverts_the_underlying_ciphertext_correctly
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'old note')
    patient.notes = 'new note'
    patient.restore_attributes(['notes'])
    assert_equal 'old note', patient.notes
    refute patient.changed?
  end

  def test_a_corrupted_current_value_does_not_block_overwriting_it
    patient = DirtyEncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    row = @store.find(:patients, patient.id)
    tampered = row.dup
    tampered['notes'] = row['notes'].sub(/^./) { |c| c == 'A' ? 'B' : 'A' }
    @store.update(:patients, patient.id, tampered)
    reloaded = DirtyEncryptedPatient.find(patient.id)
    reloaded.notes = 'fresh note'
    assert_equal 'fresh note', reloaded.notes
  end
end
