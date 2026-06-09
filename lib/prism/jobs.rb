require_relative 'jobs/job'
require_relative 'jobs/queue'
require_relative 'jobs/worker'

module Prism
  module Jobs
    class << self
      attr_writer :default_queue

      def default_queue
        @default_queue ||= Queue.new('db/jobs.pstore')
      end
    end
  end
end
