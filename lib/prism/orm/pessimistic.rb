module Prism
  module Orm
    # ActiveRecord::Locking::Pessimistic-lite. Where Locking (optimistic,
    # lock_version) detects a conflict AFTER the fact and raises
    # StaleObjectError, this PREVENTS the conflict from happening at all -
    # it holds Store's real cross-process file lock (PStore#transaction
    # flocks the underlying file with File::LOCK_EX, see
    # Store#within_transaction) for as long as the caller's block runs, so a
    # concurrent process racing on the same row cannot even start its own
    # transaction until this one commits or rolls back. No extra column,
    # no schema opt-in - it rides the file lock every transaction already
    # takes.
    #
    # `lock!` alone is exactly as limited as in ActiveRecord: it opens and
    # closes its OWN one-statement transaction, so the lock is released the
    # instant it returns - by the time the caller's next line runs, another
    # process could already have grabbed the file lock in between. The
    # useful entry point is `with_lock`, which keeps a single transaction
    # (and therefore the file lock) open across the reload AND the block.
    module Pessimistic
      class UnpersistedRecordError < StandardError
        def initialize
          super('cannot lock a record that has not been saved yet')
        end
      end

      # Rails raises the same shape of error: reload would silently throw
      # away in-memory changes the caller has not saved, which is very
      # unlikely to be what anyone locking a record for a critical section
      # actually wants.
      class DirtyRecordError < StandardError
        def initialize
          super('cannot lock a record with unsaved changes - save or ' \
                'discard them first, reload would silently drop them')
        end
      end

      # Reloads this record inside a (possibly brand new) transaction. When
      # there is no transaction open yet, `transaction` here opens a real
      # one around just this reload, which - same limitation as Rails - is
      # gone again as soon as this method returns. Called from inside
      # `with_lock` instead, it joins that already-open transaction, so the
      # exclusive file lock acquired to open it is still held afterwards.
      def lock!
        raise UnpersistedRecordError if id.nil?
        raise DirtyRecordError if changed?
        transaction { reload }
        self
      end

      # Opens a transaction, locks this record inside it, then runs the
      # block still inside that same transaction - the file lock taken to
      # open it stays held for the block's entire duration, so any other
      # process attempting its own transaction on this Store blocks until
      # this one commits (or rolls back). That is what actually prevents
      # the lost-update race `lock!` alone cannot: two processes both
      # reading the pre-update value and both writing based on it.
      def with_lock
        transaction do
          lock!
          yield self
        end
      end
    end
  end
end
