defmodule Jido.MCP.PeriErrorRegressionTest do
  use ExUnit.Case, async: true

  test "Peri.Error.error_to_map handles nested errors with nil content" do
    error = %Peri.Error{
      message: "Validation failed",
      content: %{expected: :string, actual: :integer},
      path: [:user, :age],
      key: :age,
      errors: [
        %Peri.Error{
          message: "Expected type string, got integer",
          content: nil,
          path: [:user, :age],
          key: :age,
          errors: nil
        }
      ]
    }

    assert %{
             content: %{expected: :string, actual: :integer},
             errors: [%{content: nil}]
           } = Peri.Error.error_to_map(error)
  end
end
