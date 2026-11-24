# frozen_string_literal: true

module Aetheryon
  module Editorial
    # Cliente de Groq (API compatible con OpenAI): JSON mode, reintentos con backoff, límites de concurrencia y de RPM.
    class GroqError < StandardError
      attr_reader :retriable, :retries, :latency_ms

      def initialize(msg, retriable: true, retries: 0, latency_ms: 0)
        super(msg)
        @retriable = retriable
        @retries = retries
        @latency_ms = latency_ms
      end
    end

    GroqResult = Struct.new(:text, :model, :prompt_tokens, :completion_tokens, :total_tokens, :latency_ms, :retries)

    class GroqClient
      # indirección para poder neutralizar las esperas en tests
      class << self
        attr_writer :sleeper

        def sleeper = @sleeper || ->(s) { sleep(s) }
      end

      def initialize(client, settings)
        @client = client
        @s = settings
        @sem = SizedQueue.new([1, settings.groq_concurrency].max)
        @lock = Mutex.new
        @next_slot = 0.0
      end

      def chat_json(messages)
        s = @s
        raise GroqError.new("GROQ_API_KEY no configurada", retriable: false) if s.groq_api_key.nil? || s.groq_api_key.empty?

        payload = { "model" => s.groq_model, "messages" => messages, "temperature" => s.groq_temperature,
                    "max_tokens" => s.groq_max_tokens, "response_format" => { "type" => "json_object" } }
        headers = { "Authorization" => "Bearer #{s.groq_api_key}" }
        url = "#{s.groq_base_url.sub(%r{/+\z}, '')}/chat/completions"
        t0 = mono
        last = "error"
        (s.groq_max_retries + 1).times do |attempt|
          retry_after = nil
          r = nil
          begin
            @sem.push(1)
            begin
              pace
              r = @client.post_json(url, payload, headers: headers, timeout: s.groq_timeout)
            ensure
              @sem.pop
            end
          rescue HttpError => e
            last = "Red/timeout: #{e.message}"
          end
          if r
            return parse(r, attempt, t0) if r.status == 200

            last = "HTTP #{r.status}: #{err_msg(r)}"
            retriable = [408, 409, 425, 429].include?(r.status) || r.status >= 500
            raise GroqError.new(last, retriable: false, retries: attempt, latency_ms: ms(t0)) unless retriable

            retry_after = retry_after_of(r)
          end
          raise GroqError.new(last, retriable: true, retries: attempt, latency_ms: ms(t0)) if attempt == s.groq_max_retries

          self.class.sleeper.call([60.0, retry_after.nil? ? 2.0**attempt + rand : retry_after].min)
        end
        raise GroqError, last # inalcanzable
      end

      private

      def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def ms(t0) = ((mono - t0) * 1000).to_i

      # Espaciado mínimo entre solicitudes para no superar GROQ_MAX_RPM.
      def pace
        return if @s.groq_max_rpm <= 0

        wait = @lock.synchronize do
          now = mono
          w = [0.0, @next_slot - now].max
          @next_slot = [now, @next_slot].max + 60.0 / @s.groq_max_rpm
          w
        end
        self.class.sleeper.call(wait) if wait.positive?
      end

      def err_msg(r)
        r.json.dig("error", "message").to_s[0, 200]
      rescue StandardError
        r.text[0, 200]
      end

      def retry_after_of(r)
        v = r.headers["retry-after"]
        v ? [0.0, Float(v)].max : nil
      rescue ArgumentError, TypeError
        nil
      end

      def parse(r, retries, t0)
        data =
          begin
            r.json
          rescue JSON::ParserError
            bad("ValueError", retries, t0)
          end
        bad("TypeError", retries, t0) unless data.is_a?(Hash)
        choices = data["choices"]
        bad("KeyError", retries, t0) unless choices.is_a?(Array)
        bad("IndexError", retries, t0) if choices.empty?
        text = choices[0].is_a?(Hash) && choices[0]["message"].is_a?(Hash) ? choices[0]["message"]["content"] : nil
        bad("ValueError", retries, t0) if !text.is_a?(String) || Util.py_strip(text).empty?
        u = data["usage"].is_a?(Hash) ? data["usage"] : {}
        pt = (u["prompt_tokens"] || 0).to_i
        ct = (u["completion_tokens"] || 0).to_i
        GroqResult.new(text, (data["model"] || @s.groq_model).to_s, pt, ct, (u["total_tokens"] || (pt + ct)).to_i, ms(t0), retries)
      end

      def bad(kind, retries, t0)
        raise GroqError.new("Respuesta inesperada del proveedor: #{kind}", retriable: true, retries: retries, latency_ms: ms(t0))
      end
    end
  end
end
