defmodule Oracle.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Oracle.Repo

  alias Oracle.Accounts.{Users, UsersToken, UsersNotifier}

  ## Database getters

  @doc """
  Gets a users by email.

  ## Examples

      iex> get_users_by_email("foo@example.com")
      %Users{}

      iex> get_users_by_email("unknown@example.com")
      nil

  """
  def get_users_by_email(email) when is_binary(email) do
    Repo.get_by(Users, email: email)
  end

  @doc """
  Gets a users by email and password.

  ## Examples

      iex> get_users_by_email_and_password("foo@example.com", "correct_password")
      %Users{}

      iex> get_users_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_users_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    users = Repo.get_by(Users, email: email)
    if Users.valid_password?(users, password), do: users
  end

  @doc """
  Gets a single users.

  Raises `Ecto.NoResultsError` if the Users does not exist.

  ## Examples

      iex> get_users!(123)
      %Users{}

      iex> get_users!(456)
      ** (Ecto.NoResultsError)

  """
  def get_users!(id), do: Repo.get!(Users, id)

  ## Users registration

  @doc """
  Registers a users.

  ## Examples

      iex> register_users(%{field: value})
      {:ok, %Users{}}

      iex> register_users(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_users(attrs) do
    %Users{}
    |> Users.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the users is in sudo mode.

  The users is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(users, minutes \\ -20)

  def sudo_mode?(%Users{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_users, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the users email.

  See `Oracle.Accounts.Users.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_users_email(users)
      %Ecto.Changeset{data: %Users{}}

  """
  def change_users_email(users, attrs \\ %{}, opts \\ []) do
    Users.email_changeset(users, attrs, opts)
  end

  @doc """
  Updates the users email using the given token.

  If the token matches, the users email is updated and the token is deleted.
  """
  def update_users_email(users, token) do
    context = "change:#{users.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UsersToken.verify_change_email_token_query(token, context),
           %UsersToken{sent_to: email} <- Repo.one(query),
           {:ok, users} <- Repo.update(Users.email_changeset(users, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UsersToken, where: [users_id: ^users.id, context: ^context])) do
        {:ok, users}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the users password.

  See `Oracle.Accounts.Users.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_users_password(users)
      %Ecto.Changeset{data: %Users{}}

  """
  def change_users_password(users, attrs \\ %{}, opts \\ []) do
    Users.password_changeset(users, attrs, opts)
  end

  @doc """
  Updates the users password.

  Returns a tuple with the updated users, as well as a list of expired tokens.

  ## Examples

      iex> update_users_password(users, %{password: ...})
      {:ok, {%Users{}, [...]}}

      iex> update_users_password(users, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_users_password(users, attrs) do
    users
    |> Users.password_changeset(attrs)
    |> update_users_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_users_session_token(users) do
    {token, users_token} = UsersToken.build_session_token(users)
    Repo.insert!(users_token)
    token
  end

  @doc """
  Gets the users with the given signed token.

  If the token is valid `{users, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_users_by_session_token(token) do
    {:ok, query} = UsersToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the users with the given magic link token.
  """
  def get_users_by_magic_link_token(token) do
    with {:ok, query} <- UsersToken.verify_magic_link_token_query(token),
         {users, _token} <- Repo.one(query) do
      users
    else
      _ -> nil
    end
  end

  @doc """
  Logs the users in by magic link.

  There are three cases to consider:

  1. The users has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The users has not confirmed their email and no password is set.
     In this case, the users gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The users has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_users_by_magic_link(token) do
    {:ok, query} = UsersToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Users{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Users{confirmed_at: nil} = users, _token} ->
        users
        |> Users.confirm_changeset()
        |> update_users_and_delete_all_tokens()

      {users, token} ->
        Repo.delete!(token)
        {:ok, {users, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given users.

  ## Examples

      iex> deliver_users_update_email_instructions(users, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_users_update_email_instructions(%Users{} = users, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, users_token} = UsersToken.build_email_token(users, "change:#{current_email}")

    Repo.insert!(users_token)
    UsersNotifier.deliver_update_email_instructions(users, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given users.
  """
  def deliver_login_instructions(%Users{} = users, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, users_token} = UsersToken.build_email_token(users, "login")
    Repo.insert!(users_token)
    UsersNotifier.deliver_login_instructions(users, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_users_session_token(token) do
    Repo.delete_all(from(UsersToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_users_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, users} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UsersToken, users_id: users.id)

        Repo.delete_all(from(t in UsersToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {users, tokens_to_expire}}
      end
    end)
  end
end
