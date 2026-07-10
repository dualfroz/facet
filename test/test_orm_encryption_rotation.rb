require 'minitest/autorun'
require 'prism'
require 'tmpdir'

# Key rotation for Prism::Orm::Encryption: retiring an application secret
# (a suspected leak, a scheduled policy) should not make every already-
# encrypted row unreadable the moment the new secret goes live. These tests
# encrypt a row under an OLD secret, then simulate the moment of rotation
# (primary_key flips to a new secret, the old one moves to previous_keys),
# and check that reads/queries against the old row keep working while
# writes immediately start using the new key.
class OrmEncryptionRotationTest < Minitest::Test
  OLD_SECRET = 'rotation-old-secret-do-not-use-in-prod'.freeze
  NEW_SECRET = 'rotation-new-secret-do-not-use-in-prod'.freeze

  def setup
    @dir = Dir.mktmpdir('prism-encryption-rotation-store')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:patients, %w[id name ssn notes])
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Prism::Orm::Encryption.primary_key = nil
    Prism::Orm::Encryption.previous_keys = []
    Object.send(:remove_const, :RotatingPatient) if Object.const_defined?(:RotatingPatient)
  end

  def define_patient_class
    klass = Class.new(Prism::Orm::Model) do
      table_name :patients
      encrypts :ssn, deterministic: true
      encrypts :notes
    end
    klass.store = @store
    Object.const_set(:RotatingPatient, klass)
    klass
  end

  def test_a_row_encrypted_under_the_old_key_is_unreadable_without_rotation_configured
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    new_class = define_patient_class

    error = assert_raises(Prism::Orm::Encryption::Error) { new_class.find(patient.id).notes }
    assert_match(/wrong key/, error.message)
  end

  def test_a_row_encrypted_under_the_old_key_stays_readable_once_rotation_is_configured
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    reloaded = new_class.find(patient.id)
    assert_equal '123-45-6789', reloaded.ssn
    assert_equal 'pre-rotation note', reloaded.notes
  end

  def test_a_row_re_saved_after_rotation_is_re_encrypted_under_the_new_key
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'pre-rotation note')

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    record = new_class.find(patient.id)
    record.notes = 'still the same note, just re-saved'
    record.save!

    # Once re-saved, the OLD key alone (rotation not configured on THIS
    # class) must no longer be able to decrypt it - proving the write path
    # switched to the new key rather than continuing to use whichever key
    # happened to work on read.
    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    Prism::Orm::Encryption.previous_keys = []
    old_key_only_class = define_patient_class
    error = assert_raises(Prism::Orm::Encryption::Error) { old_key_only_class.find(patient.id).notes }
    assert_match(/wrong key/, error.message)
  end

  def test_where_on_a_deterministic_column_finds_rows_encrypted_under_either_key
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    stale = old_class.create!(name: 'Stale', ssn: '555-55-5555', notes: 'n')

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class
    fresh = new_class.create!(name: 'Fresh', ssn: '555-55-5555', notes: 'n')

    found = new_class.where(ssn: '555-55-5555').to_a.map(&:id).sort
    assert_equal [stale.id, fresh.id].sort, found
  end

  def test_find_by_on_a_deterministic_column_matches_a_row_still_encrypted_under_the_old_key
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    stale = old_class.create!(name: 'Stale', ssn: '999-99-9999', notes: 'n')

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    found = new_class.find_by(ssn: '999-99-9999')
    assert_equal stale.id, found.id
  end

  def test_per_attribute_previous_keys_overrides_the_global_rotation_list
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = ['a-secret-that-was-never-used']

    scoped_old_class = Class.new(Prism::Orm::Model) do
      table_name :patients
      encrypts :notes, key: OLD_SECRET
    end
    scoped_old_class.store = @store
    patient = scoped_old_class.create!(name: 'Alice', notes: 'scoped secret note')

    scoped_new_class = Class.new(Prism::Orm::Model) do
      table_name :patients
      encrypts :notes, key: NEW_SECRET, previous_keys: [OLD_SECRET]
    end
    scoped_new_class.store = @store

    assert_equal 'scoped secret note', scoped_new_class.find(patient.id).notes
  end

  def test_a_tampered_ciphertext_still_raises_even_with_rotation_configured
    Prism::Orm::Encryption.primary_key = OLD_SECRET
    old_class = define_patient_class
    patient = old_class.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    row = @store.find(:patients, patient.id)
    tampered = row.dup
    tampered['notes'] = row['notes'].sub(/^./) { |c| c == 'A' ? 'B' : 'A' }
    @store.update(:patients, patient.id, tampered)

    Object.send(:remove_const, :RotatingPatient)
    Prism::Orm::Encryption.primary_key = NEW_SECRET
    Prism::Orm::Encryption.previous_keys = [OLD_SECRET]
    new_class = define_patient_class

    assert_raises(Prism::Orm::Encryption::Error) { new_class.find(patient.id).notes }
  end
end
