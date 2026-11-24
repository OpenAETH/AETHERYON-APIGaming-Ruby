# frozen_string_literal: true

module Aetheryon
  # Equivale a fastapi.HTTPException: se responde {"detail": ...} con el código indicado.
  class HTTPError < StandardError
    attr_reader :status, :detail

    def initialize(status, detail)
      super(detail.to_s)
      @status = status
      @detail = detail
    end
  end

  # Errores de validación (422) con el formato de FastAPI/Pydantic v2: {"detail": [{type, loc, msg, input, ctx}]}.
  class ValidationFailed < StandardError
    attr_reader :errors

    def initialize(errors)
      super("validation failed")
      @errors = errors
    end
  end
end
