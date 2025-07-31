#
# This file is part of ExJSONPath.
#
# Copyright 2019,2020 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule ExJSONPath do
  @moduledoc """
  This module implements a JSONPath evaluator.
  """

  alias ExJSONPath.ParsingError

  @opaque path_token :: String.t() | pos_integer()
  @opaque op :: :> | :>= | :< | :<= | :== | :!=

  @opaque compiled_path ::
            list(
              {:access, path_token()}
              | {:access, {op(), compiled_path(), term()}}
              | {:recurse, path_token()}
              | {:slice, non_neg_integer(), non_neg_integer(), non_neg_integer()}
              | :wildcard
            )

  @doc """
  Evaluate JSONPath on given input.

  Returns `{:ok, [result1 | results]}` on success, {:error, %ExJSONPath.ParsingError{}} otherwise.

  ## Examples

    iex> ExJSONPath.eval(%{"a" => %{"b" => 42}}, "$.a.b")
    {:ok, 42}

    iex> ExJSONPath.eval([%{"v" => 1}, %{"v" => 2}, %{"v" => 3}], "$[?(@.v > 1)].v")
    {:ok, [2, 3]}

    iex> ExJSONPath.eval(%{"a" => %{"b" => 42}}, "$.x.y")
    {:ok, nil}

    iex> data = %{ "a" => %{ "b" => 42 }, "arr" => [%{ "obj" => %{ "val" => 1 } }, %{ "obj" => %{ "val" => 2 } }, %{ "obj" => %{ "val" => 3 } }] }
    iex> ExJSONPath.eval(data, "$.arr")
    {:ok,
    [
      %{"obj" => %{"val" => 1}},
      %{"obj" => %{"val" => 2}},
      %{"obj" => %{"val" => 3}}
    ]}

    iex> data = %{ "a" => %{ "b" => 42 }, "arr" => [%{ "obj" => %{ "val" => 1 } }, %{ "obj" => %{ "val" => 2 } }, %{ "obj" => %{ "val" => 3 } }] }
    iex> ExJSONPath.eval(data, "$.arr..obj")
    {:ok, [%{"val" => 1}, %{"val" => 2}, %{"val" => 3}]}

    iex> data = %{ "a" => %{ "b" => 42 }, "arr" => [%{ "obj" => %{ "val" => 1 } }, %{ "obj" => %{ "val" => 2 } }, %{ "obj" => %{ "val" => 3 } }] }
    iex> ExJSONPath.eval(data, "$.arr..obj.val")
    {:ok, [1, 2, 3]}

    iex> data = %{ "a" => %{ "b" => 42 }, "arr" => [%{ "obj" => %{ "val" => 1 } }, %{ "obj" => %{ "val" => 2 } }, %{ "obj" => %{ "val" => 3 } }] }
    iex> ExJSONPath.eval(data, "$.arr[?(@.obj.val < 3)].obj.val")
    {:ok, [1, 2]}
  """
  @spec eval(term(), String.t() | compiled_path()) ::
          {:ok, list(term())} | {:error, ParsingError.t()}
  def eval(input, jsonpath),
    do: eval(input, input, jsonpath)

  @spec eval(term(), term(), String.t() | compiled_path()) ::
          {:ok, list(term())} | {:error, ParsingError.t()}
  def eval(root, input, jsonpath)

  @doc """
  Evaluate JSONPath on given input.

  `$` will select document `root`, while `@` will select item.
  Returns `{:ok, [result1 | results]}` on success, {:error, %ExJSONPath.ParsingError{}} otherwise.

  ## Examples

    iex> map = %{"a" => %{"b" => 42}}
    iex> ExJSONPath.eval(map, map["a"], "@.b")
    {:ok, 42}

    iex> map = %{"a" => %{"b" => 42}}
    iex> ExJSONPath.eval(map, map["a"], "$.a.b")
    {:ok, 42}

    iex> map = %{"a" => %{"b" => 42}}
    iex> ExJSONPath.eval(map, map["a"], "b")
    {:ok, 42}
  """
  def eval(root, input, path) when is_binary(path) do
    with {:ok, compiled} <- compile(path) do
      eval(root, input, compiled)
    end
  end

  def eval(root, input, compiled_path) when is_list(compiled_path) do
    {:ok, recurse(root, input, compiled_path)}
  end

  @doc """
  Parse and compile a path.

  Returns a {:ok, compiled_path} on success, {:error, reason} otherwise.
  """
  @spec compile(String.t()) :: {:ok, compiled_path()} | {:error, ParsingError.t()}
  def compile(path) when is_binary(path) do
    with charlist = String.to_charlist(path),
         {:ok, tokens, _} <- :jsonpath_lexer.string(charlist),
         {:ok, compiled} <- :jsonpath_parser.parse(tokens) do
      {:ok, compiled}
    else
      {:error, {_line, :jsonpath_lexer, error_desc}, _} ->
        message_string =
          error_desc
          |> :jsonpath_lexer.format_error()
          |> List.to_string()

        {:error, %ParsingError{message: message_string}}

      {:error, {_line, :jsonpath_parser, message}} ->
        message_string =
          message
          |> :jsonpath_parser.format_error()
          |> List.to_string()

        {:error, %ParsingError{message: message_string}}
    end
  end

  defp recurse(_root, item, []),
    do: item

  defp recurse(root, _item, [:root | t]),
    do: recurse(root, root, t)

  defp recurse(root, item, [:current_item | t]),
    do: recurse(root, item, t)

  defp recurse(root, enumerable, [{:access, {op, path, value}} | t])
       when is_list(enumerable) or is_map(enumerable) do
    results =
      Enum.reduce(enumerable, [], fn entry, acc ->
        item =
          case entry do
            {_key, value} -> value
            value -> value
          end

        with value_at_path <- recurse(root, item, path),
             true <- compare(op, value_at_path, value),
             leaf_value <- recurse(root, item, t) do
          [leaf_value | acc]
        else
          nil -> acc
          false -> acc
        end
      end)

    Enum.reverse(results)
  end

  defp recurse(root, map, [{:access, a} | t]) when is_map(map) do
    case Map.fetch(map, a) do
      {:ok, next_item} -> recurse(root, next_item, t)
      :error -> nil
    end
  end

  defp recurse(root, array, [{:access, a} | t]) when is_list(array) and is_integer(a) do
    case Enum.fetch(array, a) do
      {:ok, next_item} -> recurse(root, next_item, t)
      :error -> nil
    end
  end

  defp recurse(_root, _any, [{:access, _a} | _t]),
    do: nil

  defp recurse(root, enumerable, [{:recurse, a} | t] = path)
       when is_map(enumerable) or is_list(enumerable) do
    descent_results =
      Enum.reduce(enumerable, [], fn
        {_key, item}, acc ->
          acc ++ recurse(root, item, path)

        item, acc ->
          acc ++ recurse(root, item, path)
      end)

    case safe_fetch(enumerable, a) do
      {:ok, item} -> [recurse(root, item, t) | descent_results]
      :error -> descent_results
    end
  end

  defp recurse(_root, _any, [{:recurse, _a} | _t]),
    do: []

  defp recurse(_root, map, [{:slice, _first, _last, _step} | _t]) when is_map(map),
    do: nil

  defp recurse(root, enumerable, [{:slice, first, :last, step} | t]),
    do: recurse(root, enumerable, [{:slice, first, Enum.count(enumerable), step} | t])

  defp recurse(_root, _enumerable, [{:slice, index, index, _step} | _t]),
    do: nil

  defp recurse(root, enumerable, [{:slice, first, last, step} | t]) do
    enumerable
    |> Enum.slice(Range.new(first, last - 1))
    |> Enum.take_every(step)
    |> Enum.reduce([], fn item, acc -> acc ++ [recurse(root, item, t)] end)
  end

  defp recurse(root, enumerable, [{:union, union_list} | t]) do
    Enum.reduce(union_list, [], fn union_item, acc ->
      acc ++ [recurse(root, enumerable, [union_item | t])]
    end)
  end

  defp recurse(root, %{} = map, [:wildcard | t]) do
    Map.values(map)
    |> Enum.reduce([], fn item, acc -> acc ++ [recurse(root, item, t)] end)
  end

  defp recurse(root, list, [:wildcard | t]) when is_list(list) do
    Enum.reduce(list, [], fn item, acc -> acc ++ [recurse(root, item, t)] end)
  end

  defp safe_fetch(list, index) when is_list(list) and is_integer(index),
    do: Enum.fetch(list, index)

  defp safe_fetch(list, _index) when is_list(list),
    do: :error

  defp safe_fetch(%{} = map, key),
    do: Map.fetch(map, key)

  defp compare(op, value1, value2) do
    case op do
      :> ->
        value1 > value2

      :>= ->
        value1 >= value2

      :< ->
        value1 < value2

      :<= ->
        value1 <= value2

      :== ->
        value1 == value2

      :!= ->
        value1 != value2
    end
  end
end
