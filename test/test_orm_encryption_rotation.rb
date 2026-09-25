require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmEncryptionRotationTest < Minitest::Test
  OLD_SECRET = 'rotation-old-secret-do-not-use-in-prod'.freeze
  NEW_SECRET = 'rotation-new-secret-do-not-use-in-prod'.freeze

  def setup
    @dir = Dir.mktmpdir('facet-encryption-rotation-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:patients, %w[id name ssn notes])
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Facet::Orm::Encryption.primary_key = nil
    Facet::Orm::Encryption.previous_keys = []
    Object.send(:remove_const, :RotatingPatient) if Object.const_defined?(:RotatingPatient)
  end

  def define_patient_class
    klass = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :ssn, deterministic: true
      encrypts :notes
    end
    klass.store = @store
    Object.const_set(:RotatingPatient, klass)
    klass
  end

  def test_a_row_encrypted_under_the_old_key_is_unreadable_without_rotation_configured
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    new_class = define_patient_class

    error = assert_raises(Facet::Orm::Encryption::Error) { new_class.find(patient.id).notes }
    assert_match(/wrong key/, error.message)
  end

  def test_a_row_encrypted_under_the_old_key_stays_readable_once_rotation_is_configured
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    reloaded = new_class.find(patient.id)
    assert_equal '123-45-6789', reloaded.ssn
    assert_equal 'pre-rotation note', reloaded.notes
  end

  def test_a_row_re_saved_after_rotation_is_re_encrypted_under_the_new_key
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    record = new_class.find(patient.id)
    record.notes = 'still the same note, just re-saved'
    record.save!

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    Facet::Orm::Encryption.previous_keys = []
    old_key_only_class = define_patient_class
    error = assert_raises(Facet::Orm::Encryption::Error) { old_key_only_class.find(patient.id).notes }
    assert_match(/wrong key/, error.message)
  end

  def test_where_on_a_deterministic_column_finds_rows_encrypted_under_either_key
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    stale = old_class.create!(name: 'Stale', ssn: '555-55-5555', notes: 'n')

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class
    fresh = new_class.create!(name: 'Fresh', ssn: '555-55-5555', notes: 'n')

    found = new_class.where(ssn: '555-55-5555').to_a.map(&:id).sort
    assert_equal [stale.id, fresh.id].sort, found
  end

  def test_find_by_on_a_deterministic_column_matches_a_row_still_encrypted_under_the_old_key
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    stale = old_class.create!(name: 'Stale', ssn: '999-99-9999', notes: 'n')

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    found = new_class.find_by(ssn: '999-99-9999')
    assert_equal stale.id, found.id
  end

  def test_per_attribute_previous_keys_overrides_the_global_rotation_list
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = ['a-secret-that-was-never-used']

    scoped_old_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :notes, key: OLD_SECRET
    end
    scoped_old_class.store = @store
    patient = scoped_old_class.create!(name: 'Alice', notes: 'scoped secret note')

    scoped_new_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :notes, key: NEW_SECRET, previous_keys: [OLD_SECRET]
    end
    scoped_new_class.store = @store

    assert_equal 'scoped secret note', scoped_new_class.find(patient.id).notes
  end

  def test_a_tampered_ciphertext_still_raises_even_with_rotation_configured
    Facet::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    row = @store.find(:patients, patient.id)
    tampered = row.dup
    tampered['notes'] = row['notes'].sub(/^./) { |c| c == 'A' ? 'B' : 'A' }
    @store.update(:patients, patient.id, tampered)

    Object.send(:remove_const, :RotatingPatient)
    Facet::Orm::Encryption.primary_key = NEW_SECRET
    Facet::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    assert_raises(Facet::Orm::Encryption::Error) { new_class.find(patient.id).notes }
  end
end
