require 'minitest/autorun'
require 'facet'
require 'tmpdir'

class OrmEncryptionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('facet-encryption-store')
    @store = Facet::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:patients, %w[id name ssn notes])
    Facet::Orm::Encryption.primary_key = 'test-primary-key-do-not-use-in-prod'

    patient_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :ssn, deterministic: true
      encrypts :notes
    end
    patient_class.store = @store
    Object.const_set(:EncryptedPatient, patient_class)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Facet::Orm::Encryption.primary_key = nil
    Object.send(:remove_const, :EncryptedPatient) if Object.const_defined?(:EncryptedPatient)
  end

  def test_reading_back_the_attribute_returns_plaintext
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'allergic to penicillin')
    assert_equal '123-45-6789', patient.ssn
    assert_equal 'allergic to penicillin', patient.notes
  end

  def test_the_stored_column_holds_ciphertext_not_plaintext
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'secret note')
    raw_row = @store.find(:patients, patient.id)
    refute_equal '123-45-6789', raw_row['ssn']
    refute_equal 'secret note', raw_row['notes']
    refute_includes raw_row['ssn'], '123-45-6789'
  end

  def test_plaintext_survives_a_reload_from_disk
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    reloaded = EncryptedPatient.find(patient.id)
    assert_equal '123-45-6789', reloaded.ssn
    assert_equal 'note', reloaded.notes
  end

  def test_non_deterministic_column_produces_different_ciphertext_each_time
    a = EncryptedPatient.create!(name: 'A', ssn: '111-11-1111', notes: 'same note')
    b = EncryptedPatient.create!(name: 'B', ssn: '222-22-2222', notes: 'same note')
    raw_a = @store.find(:patients, a.id)
    raw_b = @store.find(:patients, b.id)
    refute_equal raw_a['notes'], raw_b['notes']
  end

  def test_deterministic_column_produces_the_same_ciphertext_for_the_same_plaintext
    a = EncryptedPatient.create!(name: 'A', ssn: '999-99-9999', notes: 'x')
    b = EncryptedPatient.create!(name: 'B', ssn: '999-99-9999', notes: 'y')
    raw_a = @store.find(:patients, a.id)
    raw_b = @store.find(:patients, b.id)
    assert_equal raw_a['ssn'], raw_b['ssn']
  end

  def test_where_on_a_deterministic_column_matches_by_plaintext
    match = EncryptedPatient.create!(name: 'Match', ssn: '555-55-5555', notes: 'n')
    EncryptedPatient.create!(name: 'Other', ssn: '666-66-6666', notes: 'n')
    found = EncryptedPatient.where(ssn: '555-55-5555').to_a
    assert_equal [match.id], found.map(&:id)
  end

  def test_find_by_on_a_deterministic_column_matches_by_plaintext
    match = EncryptedPatient.create!(name: 'Match', ssn: '777-77-7777', notes: 'n')
    found = EncryptedPatient.find_by(ssn: '777-77-7777')
    assert_equal match.id, found.id
  end

  def test_querying_a_non_deterministic_column_by_plaintext_raises
    error = assert_raises(Facet::Orm::Encryption::Error) { EncryptedPatient.where(notes: 'anything').to_a }
    assert_match(/not deterministic/, error.message)
  end

  def test_nil_round_trips_as_nil
    patient = EncryptedPatient.create!(name: 'Nil', ssn: nil, notes: nil)
    assert_nil patient.ssn
    assert_nil patient.notes
    raw_row = @store.find(:patients, patient.id)
    assert_nil raw_row['ssn']
    reloaded = EncryptedPatient.find(patient.id)
    assert_nil reloaded.ssn
  end

  def test_a_tampered_ciphertext_raises_on_read_instead_of_returning_garbage
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    row = @store.find(:patients, patient.id)
    tampered = row.dup
    tampered['notes'] = row['notes'].sub(/^./) { |c| c == 'A' ? 'B' : 'A' }
    @store.update(:patients, patient.id, tampered)
    reloaded = EncryptedPatient.find(patient.id)
    assert_raises(Facet::Orm::Encryption::Error) { reloaded.notes }
  end

  def test_encrypted_attributes_are_hidden_from_json_by_default
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    hash = patient.serializable_hash
    refute_includes hash.keys, 'ssn'
    refute_includes hash.keys, 'notes'
    assert_equal 'Alice', hash['name']
  end

  def test_an_explicit_only_can_still_opt_a_hidden_column_back_into_json
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: 'note')
    hash = patient.serializable_hash(only: [:ssn])
    assert_equal patient['ssn'], hash['ssn']
  end

  def test_two_different_attributes_on_the_same_record_get_independent_keys
    patient = EncryptedPatient.create!(name: 'Alice', ssn: '123-45-6789', notes: '123-45-6789')
    row = @store.find(:patients, patient.id)
    refute_equal row['ssn'], row['notes']
  end

  def test_a_column_scoped_key_overrides_the_shared_primary_key
    scoped_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :notes, key: 'a-completely-different-secret'
    end
    scoped_class.store = @store
    record = scoped_class.create!(name: 'Bob', notes: 'private')
    assert_equal 'private', record.notes

    default_key_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :notes
    end
    default_key_class.store = @store
    assert_raises(Facet::Orm::Encryption::Error) { default_key_class.find(record.id).notes }
  end

  def test_encrypts_without_any_key_configured_raises_a_clear_error
    Facet::Orm::Encryption.primary_key = nil
    unconfigured_class = Class.new(Facet::Orm::Model) do
      table_name :patients
      encrypts :notes
    end
    unconfigured_class.store = @store
    error = assert_raises(Facet::Orm::Encryption::Error) { unconfigured_class.new(notes: 'x') }
    assert_match(/primary_key=/, error.message)
  end
end
