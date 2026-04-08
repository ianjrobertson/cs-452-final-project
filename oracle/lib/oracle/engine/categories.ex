defmodule Oracle.Engine.Categories do
  alias Oracle.Repo
  alias Oracle.Categories.Category
  alias Oracle.Engine.Embeddings

  @category_names ~w(finance politics crypto sports science tech)

  @ets_table :categories_cache

  def classify(question_embedding) do
    all()
    |> Enum.max_by(fn cat -> Embeddings.cosine_similarity(question_embedding, cat.embedding) end)
    |> Map.get(:name)
    |> String.to_existing_atom()
  end

  def all do
    case ets_lookup() do
      {:ok, categories} -> categories
      :miss -> load_and_cache()
    end
  end

  def seed do
    Enum.each(@category_names, fn name ->
      unless Repo.get_by(Category, name: name) do
        {:ok, embedding} = Embeddings.embed(name)

        %Category{}
        |> Category.changeset(%{name: name, embedding: embedding})
        |> Repo.insert!()
      end
    end)

    invalidate_cache()
  end

  def invalidate_cache do
    if ets_table_exists?(), do: :ets.delete_all_objects(@ets_table)
  end

  defp load_and_cache do
    categories = Repo.all(Category)
    ensure_ets_table()
    :ets.insert(@ets_table, {:categories, categories})
    categories
  end

  defp ets_lookup do
    if ets_table_exists?() do
      case :ets.lookup(@ets_table, :categories) do
        [{:categories, categories}] -> {:ok, categories}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp ensure_ets_table do
    unless ets_table_exists?() do
      :ets.new(@ets_table, [:set, :public, :named_table])
    end
  end

  defp ets_table_exists? do
    :ets.whereis(@ets_table) != :undefined
  end
end
