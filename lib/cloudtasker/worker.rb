# frozen_string_literal: true

module Cloudtasker
  # Cloud Task based workers
  module Worker
    # Add class method to including class
    def self.included(base)
      base.extend(ClassMethods)
      base.attr_accessor :job_args, :job_id, :job_meta, :job_reenqueued, :job_retries
    end

    #
    # Return a worker instance from a serialized worker.
    # A worker can be serialized by calling `MyWorker#to_json`
    #
    # @param [String] json Worker serialized as json.
    #
    # @return [Cloudtasker::Worker, nil] The instantiated worker.
    #
    def self.from_json(json)
      from_hash(JSON.parse(json))
    rescue JSON::ParserError
      nil
    end

    #
    # Return a worker instance from a worker hash description.
    # A worker hash description is typically generated by calling `MyWorker#to_h`
    #
    # @param [Hash] hash A worker hash description.
    #
    # @return [Cloudtasker::Worker, nil] The instantiated worker.
    #
    def self.from_hash(hash)
      # Symbolize metadata keys and stringify job arguments
      payload = JSON.parse(hash.to_json, symbolize_names: true)
      payload[:job_args] = JSON.parse(hash[:job_args].to_json)

      # Extract worker parameters
      klass_name = payload&.dig(:worker)
      return nil unless klass_name

      # Check that worker class is a valid worker
      worker_klass = Object.const_get(klass_name)
      return nil unless worker_klass.include?(self)

      # Return instantiated worker
      worker_klass.new(payload.slice(:job_args, :job_id, :job_meta, :job_retries))
    rescue NameError
      nil
    end

    # Module class methods
    module ClassMethods
      #
      # Set the worker runtime options.
      #
      # @param [Hash] opts The worker options.
      #
      # @return [Hash] The options set.
      #
      def cloudtasker_options(opts = {})
        opt_list = opts&.map { |k, v| [k.to_sym, v] } || [] # symbolize
        @cloudtasker_options_hash = Hash[opt_list]
      end

      #
      # Return the worker runtime options.
      #
      # @return [Hash] The worker runtime options.
      #
      def cloudtasker_options_hash
        @cloudtasker_options_hash || {}
      end

      #
      # Enqueue worker in the backgroundf.
      #
      # @param [Array<any>] *args List of worker arguments
      #
      # @return [Cloudtasker::CloudTask] The Google Task response
      #
      def perform_async(*args)
        perform_in(nil, *args)
      end

      #
      # Enqueue worker and delay processing.
      #
      # @param [Integer, nil] interval The delay in seconds.
      # @param [Array<any>] *args List of worker arguments.
      #
      # @return [Cloudtasker::CloudTask] The Google Task response
      #
      def perform_in(interval, *args)
        new(job_args: args).schedule(interval: interval)
      end

      #
      # Enqueue worker and delay processing.
      #
      # @param [Time, Integer] time_at The time at which the job should run.
      # @param [Array<any>] *args List of worker arguments
      #
      # @return [Cloudtasker::CloudTask] The Google Task response
      #
      def perform_at(time_at, *args)
        new(job_args: args).schedule(time_at: time_at)
      end

      #
      # Return the numbeer of times this worker will be retried.
      #
      # @return [Integer] The number of retries.
      #
      def max_retries
        cloudtasker_options_hash[:max_retries] || Cloudtasker.config.max_retries
      end
    end

    #
    # Build a new worker instance.
    #
    # @param [Array<any>] job_args The list of perform args.
    # @param [String] job_id A unique ID identifying this job.
    #
    def initialize(job_args: [], job_id: nil, job_meta: {}, job_retries: 0)
      @job_args = job_args
      @job_id = job_id || SecureRandom.uuid
      @job_meta = MetaStore.new(job_meta)
      @job_retries = job_retries || 0
    end

    #
    # Return the Cloudtasker logger instance.
    #
    # @return [Logger, any] The cloudtasker logger.
    #
    def logger
      @logger ||= WorkerLogger.new(self)
    end

    #
    # Execute the worker by calling the `perform` with the args.
    #
    # @return [Any] The result of the perform.
    #
    def execute
      logger.info('Starting job...')
      resp = Cloudtasker.config.server_middleware.invoke(self) do
        begin
          perform(*job_args)
        rescue StandardError => e
          try(:on_error, e)
          return raise(e) unless job_dead?

          # Flag job as dead
          logger.info('Job dead')
          try(:on_dead, e)
          raise(DeadWorkerError, e)
        end
      end
      logger.info('Job done')
      resp
    end

    #
    # Enqueue a worker, with or without delay.
    #
    # @param [Integer] interval The delay in seconds.
    #
    # @param [Time, Integer] interval The time at which the job should run
    #
    # @return [Cloudtasker::CloudTask] The Google Task response
    #
    def schedule(interval: nil, time_at: nil)
      Cloudtasker.config.client_middleware.invoke(self) do
        WorkerHandler.new(self).schedule(interval: interval, time_at: time_at)
      end
    end

    #
    # Helper method used to re-enqueue the job. Re-enqueued
    # jobs keep the same job_id.
    #
    # This helper may be useful when jobs must pause activity due to external
    # factors such as when a third-party API is throttling the rate of API calls.
    #
    # @param [Integer] interval Delay to wait before processing the job again (in seconds).
    #
    # @return [Cloudtasker::CloudTask] The Google Task response
    #
    def reenqueue(interval)
      @job_reenqueued = true
      schedule(interval: interval)
    end

    #
    # Return a new instance of the worker with the same args and metadata
    # but with a different id.
    #
    # @return [<Type>] <description>
    #
    def new_instance
      self.class.new(job_args: job_args, job_meta: job_meta)
    end

    #
    # Return a hash description of the worker.
    #
    # @return [Hash] The worker hash description.
    #
    def to_h
      {
        worker: self.class.to_s,
        job_id: job_id,
        job_args: job_args,
        job_meta: job_meta.to_h,
        job_retries: job_retries
      }
    end

    #
    # Return a json representation of the worker.
    #
    # @param [Array<any>] *args Arguments passed to to_json.
    #
    # @return [String] The worker json representation.
    #
    def to_json(*args)
      to_h.to_json(*args)
    end

    #
    # Equality operator.
    #
    # @param [Any] other The object to compare.
    #
    # @return [Boolean] True if the object is equal.
    #
    def ==(other)
      other.is_a?(self.class) && other.job_id == job_id
    end

    #
    # Return true if the job has excceeded its maximum number
    # of retries
    #
    # @return [Boolean] True if the job is dead
    #
    def job_dead?
      job_retries >= Cloudtasker.config.max_retries
    end
  end
end
